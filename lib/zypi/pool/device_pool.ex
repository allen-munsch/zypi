defmodule Zypi.Pool.DevicePool do
  @moduledoc """
  Manages a pool of pre-warmed base devices for fast container startup.
  Creates ext4 images from OCI layers and exposes them via loop devices.
  """
  use GenServer
  require Logger

  alias Zypi.Image.Delta
  alias Zypi.Pool.ThinPool

  @min_pool_size 2
  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")
  @devices_dir Path.join(@data_dir, "devices")

  defstruct [devices: %{}, pending: MapSet.new()]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def acquire(image_ref) do
    GenServer.call(__MODULE__, {:acquire, image_ref})
  end

  def release(image_ref, device) do
    GenServer.cast(__MODULE__, {:release, image_ref, device})
  end

  def warm(image_ref) do
    GenServer.cast(__MODULE__, {:warm, image_ref})
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def init(_opts) do
    File.mkdir_p!(@devices_dir)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:acquire, image_ref}, _from, state) do
    case Map.get(state.devices, image_ref, []) do
      [device | rest] ->
        devices = Map.put(state.devices, image_ref, rest)
        async_replenish(image_ref)
        {:reply, {:ok, device}, %{state | devices: devices}}
      [] ->
        {:reply, {:error, :pool_empty}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = Enum.map(state.devices, fn {ref, devs} -> {ref, length(devs)} end) |> Map.new()
    {:reply, status, state}
  end

  @impl true
  def handle_cast({:warm, image_ref}, state) do
    Logger.info("DevicePool: Received warm request for #{image_ref}")
    if MapSet.member?(state.pending, image_ref) do
      {:noreply, state}
    else
      state = %{state | pending: MapSet.put(state.pending, image_ref)}
      parent = self()
      Task.start(fn -> do_warm(image_ref, parent) end)
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:release, image_ref, device}, state) do
    current = Map.get(state.devices, image_ref, [])
    devices = Map.put(state.devices, image_ref, [device | current])
    {:noreply, %{state | devices: devices}}
  end

  @impl true
  def handle_info({:warmed, image_ref, {:ok, device}}, state) do
    Logger.info("DevicePool: Successfully warmed device for #{image_ref}. Device: #{device}")
    current = Map.get(state.devices, image_ref, [])
    devices = Map.put(state.devices, image_ref, [device | current])
    pending = MapSet.delete(state.pending, image_ref)
    state = %{state | devices: devices, pending: pending}

    if length(Map.get(state.devices, image_ref, [])) < @min_pool_size do
      async_replenish(image_ref)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:warmed, image_ref, {:error, reason}}, state) do
    Logger.error("DevicePool: Failed to warm device for #{image_ref}: #{inspect(reason)}")
    pending = MapSet.delete(state.pending, image_ref)
    {:noreply, %{state | pending: pending}}
  end

  defp async_replenish(image_ref) do
    GenServer.cast(__MODULE__, {:warm, image_ref})
  end

  defp do_warm(image_ref, parent) do
    result = with {:ok, manifest} <- Delta.get(image_ref),
                  {:ok, base_image} <- ensure_base_image(image_ref, manifest),
                  {:ok, device} <- attach_loop_device(base_image),
                  :ok <- ThinPool.setup_image_pool(image_ref, device) do
      {:ok, device}
    end
    send(parent, {:warmed, image_ref, result})
  end

  defp ensure_base_image(image_ref, manifest) do
    image_id = Base.url_encode64(image_ref, padding: false)
    image_path = Path.join(@devices_dir, "#{image_id}.img")

    if File.exists?(image_path) do
      {:ok, image_path}
    else
      create_base_image(image_path, manifest)
    end
  end

  defp create_base_image(image_path, manifest) do
    layer_size = manifest.size_bytes || 0
    size_mb = max(64, div(layer_size * 120, 100 * 1024 * 1024) + 32)
    work_dir = Path.join(Path.dirname(image_path), "work_#{:erlang.unique_integer([:positive])}")
    rootfs_dir = Path.join(work_dir, "rootfs")
    mount_point = Path.join(work_dir, "mnt")

    try do
      File.mkdir_p!(rootfs_dir)
      File.mkdir_p!(mount_point)

      config = manifest.overlaybd_config
      config_map = if is_binary(config), do: Jason.decode!(config), else: config
      layers_url = config_map["repoBlobUrl"] || ""
      layers_path = String.replace_prefix(layers_url, "file://", "")
      lowers = config_map["lowers"] || []

      layers_found = Enum.reduce(lowers, 0, fn layer, count ->
        digest = layer["digest"]
        layer_file = Path.join(layers_path, digest)
        if File.exists?(layer_file) do
          Logger.debug("Extracting layer #{String.slice(digest, 7, 12)}")
          System.cmd("tar", ["-xf", layer_file, "-C", rootfs_dir], stderr_to_stdout: true)
          count + 1
        else
          Logger.warning("Layer not found: #{layer_file}")
          count
        end
      end)

      if layers_found == 0 and length(lowers) > 0 do
        Logger.error("No layers found - check that registry path is accessible")
      end

      with {_, 0} <- System.cmd("truncate", ["-s", "#{size_mb}M", image_path]),
           {_, 0} <- System.cmd("mkfs.ext4", ["-F", "-q", image_path]),
           {:ok, loop} <- attach_loop_device(image_path),
           {_, 0} <- System.cmd("mount", [loop, mount_point]),
           :ok <- copy_rootfs(rootfs_dir, mount_point),
           {_, 0} <- System.cmd("umount", [mount_point]),
           {_, 0} <- System.cmd("losetup", ["-d", loop]) do
        Logger.info("DevicePool: Created base image #{image_path} (#{size_mb}MB, #{layers_found} layers)")
        {:ok, image_path}
      else
        {err, code} ->
          File.rm(image_path)
          {:error, {:image_creation_failed, code, err}}
        {:error, _} = err ->
          File.rm(image_path)
          err
      end
    after
      File.rm_rf(work_dir)
    end
  end

  defp copy_rootfs(src, dst) do
    files = Path.wildcard("#{src}/*") ++ Path.wildcard("#{src}/.*")
    |> Enum.reject(&(Path.basename(&1) in [".", ".."]))
    case files do
      [] ->
        Logger.warning("Rootfs is empty, creating minimal structure")
        File.mkdir_p!(Path.join(dst, "bin"))
        File.mkdir_p!(Path.join(dst, "tmp"))
        :ok
      _ ->
        System.cmd("cp", ["-a"] ++ files ++ [dst], stderr_to_stdout: true)
        :ok
    end
  end

  defp attach_loop_device(image_path) do
    # Check if already attached
    case System.cmd("losetup", ["-j", image_path], stderr_to_stdout: true) do
      {output, 0} when output != "" ->
        # Already attached, extract device path
        [device | _] = String.split(output, ":")
        {:ok, String.trim(device)}
      _ ->
        # Not attached, create new
        case System.cmd("losetup", ["--find", "--show", image_path], stderr_to_stdout: true) do
          {output, 0} -> {:ok, String.trim(output)}
          {err, code} -> {:error, {:losetup_failed, code, err}}
        end
    end
  end
end
