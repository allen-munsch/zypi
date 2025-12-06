defmodule Zypi.Image.Importer do
  @moduledoc """
  Imports Docker tar archives into Zypi image store.
  Extracts layers, parses OCI config, stores container metadata.
  """
  require Logger
  import Bitwise  # We need this for the &&& operator

  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")

  defmodule ContainerConfig do
    @derive Jason.Encoder
    defstruct [:cmd, :entrypoint, :env, :workdir, :user]
  end

  def import_tar(ref, tar_data) do
    Logger.info("Importer: Starting import for #{ref}")

    with {:ok, work_dir} <- mktemp_workdir(),
         {:ok, extracted_dir} <- extract_tar(tar_data, work_dir),
         {:ok, docker_manifest, oci_config} <- parse_docker_tar(extracted_dir),
         {:ok, layers, total_size} <- process_layers(ref, extracted_dir, docker_manifest),
         container_config = extract_container_config(oci_config),
         {:ok, manifest} <- create_delta(ref, layers, total_size, container_config) do

      # DEBUG: List the rootfs contents
      # We don't have the rootfs path in the manifest, so we need to get it from the delta?
      # But the delta is stored in the delta_path, and the rootfs is built by the overlaybd.
      # We are not building the rootfs in the importer. The rootfs is built when the container is created.
      # So we cannot check for /sbin/init here because the rootfs doesn't exist yet.

      # Instead, we can check the layers? But the layers are tar files.

      # We'll just log the layers and the config.

      Logger.info("Imported #{ref}: #{length(layers)} layers, #{total_size} bytes")

      # We don't have a rootfs path to check, so we skip the rootfs checks.

      {:ok, manifest}
    else
      error ->
        Logger.error("Import failed: #{inspect(error)}")
        error
    end
  end

  defp mktemp_workdir() do
    work_dir = Path.join(System.tmp_dir!(), "zypi-import-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work_dir)
    {:ok, work_dir}
  end

  defp extract_tar(tar_data, work_dir) do
    tar_path = Path.join(work_dir, "image.tar")
    File.write!(tar_path, tar_data)
    case System.cmd("tar", ["xf", tar_path, "-C", work_dir]) do
      {_, 0} -> {:ok, work_dir}
      {output, code} -> {:error, {:tar_failed, code, output}}
    end
  end

  # The rest of the functions are provided in the error message, so we can use them.

  defp ensure_success({_output, 0}), do: :ok
  defp ensure_success({output, exit_code}), do: {:error, {:cmd_failed, exit_code, output}}

  defp stream_body_to_file(conn, path) do
    {:ok, file} = File.open(path, [:write, :binary])
    result = do_stream(conn, file)
    File.close(file)
    result
  end

  defp do_stream(conn, file) do
    case Plug.Conn.read_body(conn, length: 1_000_000) do
      {:ok, body, conn} ->
        IO.binwrite(file, body)
        {:ok, conn}
      {:more, body, conn} ->
        IO.binwrite(file, body)
        do_stream(conn, file)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_docker_tar(extract_dir) do
    manifest_path = Path.join(extract_dir, "manifest.json")
    {:ok, json} = File.read(manifest_path)
    [docker_manifest] = Jason.decode!(json)

    config_path = Path.join(extract_dir, docker_manifest["Config"])
    {:ok, config_json} = File.read(config_path)
    oci_config = Jason.decode!(config_json)

    {:ok, docker_manifest, oci_config}
  end

  defp process_layers(image_ref, extract_dir, docker_manifest) do
    dest_dir = layer_dir(image_ref)
    File.mkdir_p!(dest_dir)

    layer_paths = docker_manifest["Layers"] || []

    {layers, total} = Enum.map_reduce(layer_paths, 0, fn layer_path, acc ->
      src = Path.join(extract_dir, layer_path)
      {hash_out, 0} = System.cmd("sha256sum", [src])
      [hash | _] = String.split(hash_out)
      digest = "sha256:#{hash}"
      dest = Path.join(dest_dir, digest)

      case System.cmd("file", ["-b", src], stderr_to_stdout: true) do
        {out, 0} ->
          if String.contains?(out, "gzip") do
            {_, 0} = System.cmd("sh", ["-c", "gunzip -c '#{src}' > '#{dest}'"])
          else
            File.cp!(src, dest)
          end
      end

      size = File.stat!(dest).size
      {%{digest: digest, size: size}, acc + size}
    end)

    {:ok, layers, total}
  end

  defp extract_container_config(oci_config) do
    cfg = oci_config["config"] || %{}
    %ContainerConfig{
      cmd: cfg["Cmd"],
      entrypoint: cfg["Entrypoint"],
      env: cfg["Env"] || [],
      workdir: cfg["WorkingDir"] || "/",
      user: cfg["User"] || "root"
    }
  end

  defp create_delta(image_ref, layers, total_size, container_config) do
    path = delta_path(image_ref)
    File.mkdir_p!(path)

    lowers = Enum.map(layers, fn l -> %{"digest" => l.digest, "size" => l.size} end)

    overlaybd_config = %{
      "repoBlobUrl" => "file://#{layer_dir(image_ref)}",
      "lowers" => lowers,
      "resultFile" => "/tmp/zypi-#{Base.url_encode64(image_ref, padding: false)}"
    }

    manifest = %{
      ref: image_ref,
      layers: layers,
      size_bytes: total_size,
      created_at: DateTime.utc_now(),
      overlaybd_config: overlaybd_config,
      container_config: Map.from_struct(container_config)
    }

    File.write!(Path.join(path, "config.overlaybd.json"), Jason.encode!(overlaybd_config))
    File.write!(Path.join(path, "manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(path, "container_config.json"), Jason.encode!(container_config))

    Logger.info("Imported #{image_ref}: #{length(layers)} layers, #{total_size} bytes")
    Zypi.Store.Images.put(%Zypi.Store.Images.Image{ref: image_ref, status: :available})

    {:ok, manifest}
  end

  defp layer_dir(ref), do: Path.join([ @data_dir, "layers", Base.url_encode64(ref, padding: false)])
  defp delta_path(ref), do: Path.join([ @data_dir, "deltas", Base.url_encode64(ref, padding: false)])
end
