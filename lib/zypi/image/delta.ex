defmodule Zypi.Image.Delta do
  @moduledoc """
  Handles pre-built overlaybd delta bundles.
  
  Bundle format:
  - manifest.json: {ref, layers: [{digest, size}], created_at}
  - config.overlaybd.json: Pre-generated overlaybd config
  - layers/: Optional local layer cache
  """

  require Logger

  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")
  @delta_dir Path.join(@data_dir, "deltas")

  defmodule Manifest do
    @derive Jason.Encoder
    defstruct [:ref, :layers, :size_bytes, :created_at, :overlaybd_config]
  end

  def init do
    File.mkdir_p!(@delta_dir)
  end

  def push(image_ref, overlaybd_config, opts \\ []) do
    path = image_path(image_ref)
    File.mkdir_p!(path)

    manifest = %Manifest{
      ref: image_ref,
      layers: Keyword.get(opts, :layers, []),
      size_bytes: Keyword.get(opts, :size_bytes, 0),
      created_at: DateTime.utc_now(),
      overlaybd_config: overlaybd_config
    }

    config_file = Path.join(path, "config.overlaybd.json")
    manifest_file = Path.join(path, "manifest.json")

    with :ok <- File.write(config_file, overlaybd_config),
         :ok <- File.write(manifest_file, Jason.encode!(manifest)) do
      Logger.info("Delta pushed: #{image_ref}")
      Zypi.Store.Images.put(%Zypi.Store.Images.Image{ref: image_ref, status: :available})
      {:ok, manifest}
    end
  end

  def get(image_ref) do
    manifest_file = Path.join(image_path(image_ref), "manifest.json")
    case File.read(manifest_file) do
      {:ok, data} -> {:ok, Jason.decode!(data, keys: :atoms)}
      {:error, :enoent} -> {:error, :not_found}
      error -> error
    end
  end

  def config_path(image_ref) do
    path = Path.join(image_path(image_ref), "config.overlaybd.json")
    if File.exists?(path), do: {:ok, path}, else: {:error, :not_found}
  end

  def list do
    case File.ls(@delta_dir) do
      {:ok, dirs} -> Enum.map(dirs, &decode_ref/1) |> Enum.reject(&is_nil/1)
      _ -> []
    end
  end

  def delete(image_ref) do
    File.rm_rf(image_path(image_ref))
    :ok
  end

  defp image_path(image_ref) do
    encoded = Base.url_encode64(image_ref, padding: false)
    Path.join(@delta_dir, encoded)
  end

  defp decode_ref(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, ref} -> ref
      _ -> nil
    end
  end
end
