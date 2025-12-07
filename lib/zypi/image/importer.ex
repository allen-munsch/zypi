defmodule Zypi.Image.Importer do
  @moduledoc """
  Imports Docker tar archives into Zypi image store.
  Extracts layers, parses OCI config, stores container metadata.
  """
  require Logger
  import Bitwise
  alias Zypi.Image.BaseRootfs

  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")

  defmodule ContainerConfig do
    @derive Jason.Encoder
    defstruct [:cmd, :entrypoint, :env, :workdir, :user]
  end

  def import_tar(ref, tar_data) do
    Logger.info("Importer: Starting overlaybd import for #{ref}")

    with {:ok, work_dir} <- mktemp_workdir(),
         tar_path = Path.join(work_dir, "image.tar"),
         :ok <- File.write(tar_path, tar_data),
         _ = Logger.info("Wrote #{byte_size(tar_data)} bytes to #{tar_path}"),
         {:ok, format} <- validate_docker_tar(tar_path),
         _ = Logger.info("Detected image format: #{format}"),

         # Parse OCI config first to customize the base
         {:ok, oci_config} <- parse_oci_config_from_tar(tar_path),
         container_config = extract_container_config(oci_config),

         # Build a custom base rootfs with injected config
         {:ok, custom_rootfs_path} <- BaseRootfs.build_base_with_oci_config(container_config),

         # Create overlaybd config file
         config_path = Path.join(work_dir, "overlaybd.json"),
         :ok <- create_overlaybd_config(config_path, work_dir),

         # Apply base rootfs first with mkfs
         {:ok, _} <- run_overlaybd_apply(custom_rootfs_path, config_path, mkfs: true),

         # Apply Docker image tar on top
         {:ok, _} <- run_overlaybd_apply(tar_path, config_path),

         # Read final config
         {:ok, config_json} <- File.read(config_path),
         overlaybd_config = Jason.decode!(config_json),

         # Store layers and create delta
         {:ok, final_manifest} <- create_delta(ref, work_dir, overlaybd_config, container_config) do

      Logger.info("Overlaybd import successful for #{ref}")
      # Clean up the temp custom rootfs
      File.rm(custom_rootfs_path)
      {:ok, final_manifest}
    else
      error ->
        Logger.error("Overlaybd import failed: #{inspect(error)}")
        error
    end
  end

  defp run_overlaybd_apply(tar_path, config_path, opts \\ []) do
    case System.find_executable("overlaybd-apply") do
      nil ->
        {:error, {:binary_not_found, "overlaybd-apply"}}
      exe_path ->
        args = [tar_path, config_path]
        args = if Keyword.get(opts, :mkfs, false), do: args ++ ["--mkfs"], else: args
        args = if Keyword.get(opts, :verbose, false), do: args ++ ["--verbose"], else: args
        
        Logger.debug("Running: overlaybd-apply #{Enum.join(args, " ")}")
        case System.cmd(exe_path, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {err, code} -> {:error, {:overlaybd_apply_failed, code, err}}
        end
    end
  end



  defp parse_oci_config_from_tar(tar_path) do
    tmp_dir = Path.join(System.tmp_dir!(), "zypi-oci-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    try do
      # List all files in tar to find manifest
      {listing, 0} = System.cmd("tar", ["tf", tar_path], stderr_to_stdout: true)
      files = String.split(listing, "\n", trim: true)
      
      Logger.debug("Tar contents: #{inspect(Enum.take(files, 20))}")
      
      # Find manifest.json (could be ./manifest.json, manifest.json, etc)
      manifest_entry = Enum.find(files, fn f ->
        Path.basename(f) == "manifest.json" and not String.contains?(f, "/blobs/")
      end)
      
          if is_nil(manifest_entry) do
            # Try OCI layout as fallback
            Logger.info("No Docker manifest.json, trying OCI layout...")
            {_, 0} = System.cmd("tar", ["xf", tar_path, "-C", tmp_dir], stderr_to_stdout: true)
            case try_oci_layout(tmp_dir) do
              {:ok, config} -> {:ok, config}
              {:error, _} ->
                Logger.error("No manifest.json found in tar. Files: #{inspect(Enum.take(files, 30))}")
                {:error, :manifest_not_found}
            end
          else
            # Extract entire tar to avoid path issues
            {_, 0} = System.cmd("tar", ["xf", tar_path, "-C", tmp_dir], stderr_to_stdout: true)
            
            manifest_path = Path.join(tmp_dir, manifest_entry)
            Logger.debug("Reading manifest from: #{manifest_path}")
                    case File.read(manifest_path) do
          {:ok, json} ->
            parse_docker_manifest(json, tmp_dir, files)
          {:error, reason} ->
            Logger.error("Failed to read manifest at #{manifest_path}: #{inspect(reason)}")
            {:error, {:manifest_read_failed, reason}}
        end
      end
    catch
      kind, reason ->
        Logger.error("Tar parse failed: #{kind} #{inspect(reason)}")
        {:error, {:tar_parse_failed, reason}}
    after
      File.rm_rf!(tmp_dir)
    end
  end

  defp parse_docker_manifest(json, tmp_dir, _files) do
    case Jason.decode(json) do
      {:ok, [manifest | _]} when is_map(manifest) ->
        # Docker manifest format: [{"Config": "abc123.json", "Layers": [...]}]
        config_file = manifest["Config"]
        
        if is_nil(config_file) do
          Logger.error("Manifest missing Config field: #{inspect(manifest)}")
          {:error, :invalid_manifest}
        else
          config_path = Path.join(tmp_dir, config_file)
          
          case File.read(config_path) do
            {:ok, config_json} ->
              {:ok, Jason.decode!(config_json)}
            {:error, reason} ->
              Logger.error("Failed to read config #{config_path}: #{inspect(reason)}")
              {:error, {:config_read_failed, reason}}
          end
        end
        
      {:ok, other} ->
        Logger.error("Unexpected manifest format: #{inspect(other)}")
        {:error, :invalid_manifest_format}
        
      {:error, reason} ->
        Logger.error("JSON parse failed: #{inspect(reason)}")
        {:error, {:json_parse_failed, reason}}
    end
  end

  defp try_oci_layout(tmp_dir) do
    # OCI layout has index.json at root instead of manifest.json
    index_path = Path.join(tmp_dir, "index.json")
    
    case File.read(index_path) do
      {:ok, json} ->
        index = Jason.decode!(json)
        # OCI index points to manifest in blobs/sha256/
        case get_in(index, ["manifests", Access.at(0), "digest"]) do
          "sha256:" <> hash ->
            blob_path = Path.join([tmp_dir, "blobs", "sha256", hash])
            case File.read(blob_path) do
              {:ok, manifest_json} ->
                manifest = Jason.decode!(manifest_json)
                config_digest = get_in(manifest, ["config", "digest"])
                "sha256:" <> config_hash = config_digest
                config_path = Path.join([tmp_dir, "blobs", "sha256", config_hash])
                case File.read(config_path) do # Add case for File.read
                  {:ok, config_json} -> {:ok, Jason.decode!(config_json)}
                  error -> error
                end
              error -> error
            end
          _ -> {:error, :oci_layout_parse_failed}
        end
      {:error, :enoent} ->
        {:error, :not_oci_layout}
      error -> error # Catch other File.read errors for index.json
    end
  end

  # Helper to handle Docker image config paths which might contain `../`
  defp docker_path_join(path) do
    path
    |> String.replace("..", "__") # Replace ".." to avoid path traversal
    |> String.split("/")
    |> Enum.reject(&(&1 == "" || &1 == ".")) # Remove empty and current dir segments
    |> Path.join()
  end

  defp mktemp_workdir() do
    work_dir = Path.join(System.tmp_dir!(), "zypi-import-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work_dir)
    {:ok, work_dir}
  end

  defp validate_docker_tar(tar_path) do
    case System.cmd("tar", ["tf", tar_path], stderr_to_stdout: true) do
      {listing, 0} ->
        files = String.split(listing, "\n", trim: true)
        has_manifest = Enum.any?(files, &(Path.basename(&1) == "manifest.json"))
        has_index = Enum.any?(files, &(Path.basename(&1) == "index.json"))
        has_layers = Enum.any?(files, &String.ends_with?(&1, "/layer.tar"))
        
        cond do
          has_manifest -> {:ok, :docker_format}
          has_index -> {:ok, :oci_format}
          has_layers -> {:ok, :unknown_with_layers}
          true -> {:error, {:invalid_image_tar, files}}
        end
      {err, code} ->
        {:error, {:tar_read_failed, code, err}}
    end
  end

  # The rest of the functions are provided in the error message, so we can use them.

  defp create_overlaybd_config(config_path, work_dir) do
    config = %{
      "lowers" => [],
      "resultFile" => Path.join(work_dir, "result.obd")
    }
    File.write(config_path, Jason.encode!(config))
  end

  defp create_delta(image_ref, work_dir, overlaybd_config, container_config) do
    dest_dir = layer_dir(image_ref)
    File.mkdir_p!(dest_dir)

    # Copy layers and update config paths
    {new_lowers, total_size} = Enum.map_reduce(overlaybd_config["lowers"], 0, fn layer, acc ->
      src_path = layer["file"]
      dest_path = Path.join(dest_dir, Path.basename(src_path))
      File.cp!(src_path, dest_path)
      
      size = File.stat!(dest_path).size
      {%{"file" => dest_path}, acc + size}
    end)

    # Final config for storage
    final_overlaybd_config = %{
      "lowers" => new_lowers,
      "resultFile" => "/tmp/zypi-#{Base.url_encode64(image_ref, padding: false)}"
    }

    path = delta_path(image_ref)
    File.mkdir_p!(path)

    manifest = %{
      ref: image_ref,
      layers: new_lowers, # Store the overlaybd layers info
      size_bytes: total_size,
      created_at: DateTime.utc_now(),
      overlaybd_config: final_overlaybd_config,
      container_config: Map.from_struct(container_config)
    }

    File.write!(Path.join(path, "config.overlaybd.json"), Jason.encode!(final_overlaybd_config))
    File.write!(Path.join(path, "manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(path, "container_config.json"), Jason.encode!(container_config))
    
    File.rm_rf!(work_dir)

    Logger.info("Created overlaybd delta for #{image_ref}: #{length(new_lowers)} layers, #{total_size} bytes")
    Zypi.Store.Images.put(%Zypi.Store.Images.Image{ref: image_ref, status: :available})

    {:ok, manifest}
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

  defp layer_dir(ref), do: Path.join([ @data_dir, "layers", Base.url_encode64(ref, padding: false)])
  defp delta_path(ref), do: Path.join([ @data_dir, "deltas", Base.url_encode64(ref, padding: false)])
end
