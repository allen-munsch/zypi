defmodule Zypi.Pool.ImageStore do
  use GenServer
  require Logger

  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")
  @images_dir Path.join( @data_dir, "images")
  @containers_dir Path.join( @data_dir, "containers")

  defmodule ImageMeta do
    defstruct [:ref, :ext4_path, :size_bytes, :created_at, :container_config]
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def get_image(ref), do: GenServer.call(__MODULE__, {:get_image, ref})

  def put_image(ref, ext4_path, container_config, size_bytes) do
    GenServer.call(__MODULE__, {:put_image, ref, ext4_path, container_config, size_bytes})
  end

  def list_images, do: GenServer.call(__MODULE__, :list_images)

  def delete_image(ref), do: GenServer.call(__MODULE__, {:delete_image, ref})

  def image_exists?(ref), do: GenServer.call(__MODULE__, {:image_exists, ref})

  def create_snapshot(image_ref, container_id) do
    GenServer.call(__MODULE__, {:create_snapshot, image_ref, container_id}, 30_000)
  end

  def destroy_snapshot(container_id) do
    GenServer.call(__MODULE__, {:destroy_snapshot, container_id})
  end

  @impl true
  def init(_opts) do
    File.mkdir_p!( @images_dir)
    File.mkdir_p!( @containers_dir)
    images = load_existing_images()
    Logger.info("ImageStore initialized with #{map_size(images)} images")
    {:ok, %{images: images}}
  end

  @impl true
  def handle_call({:get_image, ref}, _from, state) do
    {:reply, Map.fetch(state.images, ref), state}
  end

  @impl true
  def handle_call({:put_image, ref, ext4_path, container_config, size_bytes}, _from, state) do
    meta = %ImageMeta{
      ref: ref,
      ext4_path: ext4_path,
      size_bytes: size_bytes,
      created_at: DateTime.utc_now(),
      container_config: container_config
    }
    save_image_meta(ref, meta)
    images = Map.put(state.images, ref, meta)
    {:reply, :ok, %{state | images: images}}
  end

  @impl true
  def handle_call(:list_images, _from, state) do
    {:reply, Map.keys(state.images), state}
  end

  @impl true
  def handle_call({:delete_image, ref}, _from, state) do
    case Map.get(state.images, ref) do
      nil ->
        {:reply, {:error, :not_found}, state}
      meta ->
        File.rm(meta.ext4_path)
        File.rm(meta_path(ref))
        images = Map.delete(state.images, ref)
        {:reply, :ok, %{state | images: images}}
    end
  end

  @impl true
  def handle_call({:image_exists, ref}, _from, state) do
    exists = case Map.get(state.images, ref) do
      nil -> false
      meta -> File.exists?(meta.ext4_path)
    end
    {:reply, exists, state}
  end

  @impl true
  def handle_call({:create_snapshot, image_ref, container_id}, _from, state) do
    case Map.get(state.images, image_ref) do
      nil ->
        {:reply, {:error, :image_not_found}, state}
      meta ->
        container_dir = Path.join( @containers_dir, container_id)
        File.mkdir_p!(container_dir)
        snapshot_path = Path.join(container_dir, "rootfs.ext4")
        case do_snapshot_copy(meta.ext4_path, snapshot_path) do
          :ok ->
            {:reply, {:ok, snapshot_path}, state}
          {:error, reason} ->
            File.rm_rf(container_dir)
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:destroy_snapshot, container_id}, _from, state) do
    container_dir = Path.join( @containers_dir, container_id)
    File.rm_rf(container_dir)
    {:reply, :ok, state}
  end

  defp do_snapshot_copy(source, dest) do
    case System.cmd("cp", ["--reflink=auto", source, dest], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {err, code} -> {:error, {:copy_failed, code, err}}
    end
  end

  defp load_existing_images do
    case File.ls( @images_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.reduce(%{}, fn file, acc ->
          path = Path.join( @images_dir, file)
          case File.read(path) do
            {:ok, data} ->
              meta = Jason.decode!(data, keys: :atoms)
              struct_meta = struct(ImageMeta, meta)
              Map.put(acc, struct_meta.ref, struct_meta)
            _ -> acc
          end
        end)
      _ -> %{}
    end
  end

  defp save_image_meta(ref, meta) do
    path = meta_path(ref)
    File.write!(path, Jason.encode!(Map.from_struct(meta), pretty: true))
  end

  defp meta_path(ref) do
    encoded = Base.url_encode64(ref, padding: false)
    Path.join( @images_dir, "#{encoded}.json")
  end
end
