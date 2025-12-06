defmodule Zypi.Image.Delta do
  @moduledoc """
  Handles image delta bundles with container config support.
  """
  require Logger

  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")
  @delta_dir Path.join( @data_dir, "deltas")

  defmodule Manifest do
    @derive Jason.Encoder
    defstruct [:ref, :layers, :size_bytes, :created_at, :overlaybd_config, :container_config]
  end

  def init, do: File.mkdir_p!( @delta_dir)

  def get(image_ref) do
    path = image_path(image_ref)
    manifest_file = Path.join(path, "manifest.json")

    case File.read(manifest_file) do
      {:ok, data} ->
        manifest = Jason.decode!(data, keys: :atoms)
        config_file = Path.join(path, "container_config.json")
        container_config = case File.read(config_file) do
          {:ok, cfg} -> Jason.decode!(cfg, keys: :atoms)
          _ -> %{}
        end
        {:ok, Map.put(manifest, :container_config, container_config)}
      {:error, :enoent} -> {:error, :not_found}
      error -> error
    end
  end

  def push(image_ref, overlaybd_config, opts \\ []) do
    path = image_path(image_ref)
    File.mkdir_p!(path)

    container_config = Keyword.get(opts, :container_config, %{})

    manifest = %Manifest{
      ref: image_ref,
      layers: Keyword.get(opts, :layers, []),
      size_bytes: Keyword.get(opts, :size_bytes, 0),
      created_at: DateTime.utc_now(),
      overlaybd_config: overlaybd_config,
      container_config: container_config
    }

    config_str = if is_binary(overlaybd_config), do: overlaybd_config, else: Jason.encode!(overlaybd_config)

    with :ok <- File.write(Path.join(path, "config.overlaybd.json"), config_str),
         :ok <- File.write(Path.join(path, "manifest.json"), Jason.encode!(manifest)),
         :ok <- File.write(Path.join(path, "container_config.json"), Jason.encode!(container_config)) do
      Logger.info("Delta pushed: #{image_ref}")
      Zypi.Store.Images.put(%Zypi.Store.Images.Image{ref: image_ref, status: :available})
      {:ok, manifest}
    end
  end

  def config_path(image_ref) do
    path = Path.join(image_path(image_ref), "config.overlaybd.json")
    if File.exists?(path), do: {:ok, path}, else: {:error, :not_found}
  end

  def list do
    case File.ls( @delta_dir) do
      {:ok, dirs} -> Enum.map(dirs, &decode_ref/1) |> Enum.reject(&is_nil/1)
      _ -> []
    end
  end

  def delete(image_ref) do
    layer_dir = Path.join([ @data_dir, "layers", Base.url_encode64(image_ref, padding: false)])
    File.rm_rf(layer_dir)
    File.rm_rf(image_path(image_ref))
    :ok
  end

  defp image_path(image_ref) do
    encoded = Base.url_encode64(image_ref, padding: false)
    Path.join( @delta_dir, encoded)
  end

  defp decode_ref(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, ref} -> ref
      _ -> nil
    end
  end
end