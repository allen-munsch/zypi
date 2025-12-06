defmodule Zypi.Pool.ThinPool do
  @moduledoc """
  Device-mapper thin provisioning for copy-on-write container snapshots.
  Creates thin pools from base images and provisions thin volumes for containers.
  """
  use GenServer
  require Logger

  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")
  @pool_dir Path.join(@data_dir, "thin")
  @metadata_size_mb 64
  @chunk_sectors 128  # 64KB chunks

  defstruct [:next_thin_id, pools: %{}]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def setup_image_pool(image_ref, base_device) do
    GenServer.call(__MODULE__, {:setup, image_ref, base_device}, 30_000)
  end

  def create_snapshot(image_ref, container_id) do
    GenServer.call(__MODULE__, {:snapshot, image_ref, container_id})
  end

  def destroy_snapshot(image_ref, container_id) do
    GenServer.call(__MODULE__, {:destroy, image_ref, container_id})
  end

  @impl true
  def init(_opts) do
    File.mkdir_p!(@pool_dir)
    {:ok, %__MODULE__{next_thin_id: 0}}
  end

  @impl true
  def handle_call({:setup, image_ref, base_device}, _from, state) do
    case Map.get(state.pools, image_ref) do
      nil ->
        case do_setup_pool(image_ref, base_device) do
          {:ok, pool_info} ->
            pools = Map.put(state.pools, image_ref, pool_info)
            {:reply, :ok, %{state | pools: pools}}
          {:error, _} = error ->
            {:reply, error, state}
        end
      _exists ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:snapshot, image_ref, container_id}, _from, state) do
    case Map.get(state.pools, image_ref) do
      nil ->
        {:reply, {:error, :pool_not_found}, state}
      pool_info ->
        thin_id = state.next_thin_id
        case do_create_snapshot(pool_info, thin_id, container_id) do
          {:ok, device} ->
            {:reply, {:ok, device}, %{state | next_thin_id: thin_id + 1}}
          {:error, _} = error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call({:destroy, _image_ref, container_id}, _from, state) do
    snap_name = "zypi-snap-#{container_id}"
    System.cmd("dmsetup", ["remove", "--force", snap_name], stderr_to_stdout: true)
    {:reply, :ok, state}
  end

  defp do_setup_pool(image_ref, base_device) do
    pool_name = pool_name(image_ref)

    # Check if DM device already exists
    case System.cmd("dmsetup", ["info", pool_name], stderr_to_stdout: true) do
      {_, 0} ->
        # Pool exists, recover state
        Logger.info("ThinPool: Reusing existing pool #{pool_name}")
        {:ok, size} = get_device_sectors(base_device)
        {:ok, %{name: pool_name, meta: nil, data: nil, base: base_device, size: size}}
      _ ->
        # Create new pool
        with {:ok, size_sectors} <- get_device_sectors(base_device),
            {:ok, meta_loop, data_loop} <- create_pool_devices(pool_name, size_sectors),
            :ok <- create_thin_pool_dm(pool_name, meta_loop, data_loop, size_sectors * 2) do
          {:ok, %{name: pool_name, meta: meta_loop, data: data_loop, base: base_device, size: size_sectors}}
        end
    end
  end

  defp create_pool_devices(pool_name, data_size_sectors) do
    metadata_path = Path.join(@pool_dir, "#{pool_name}.meta")
    data_path = Path.join(@pool_dir, "#{pool_name}.data")

    metadata_bytes = @metadata_size_mb * 1024 * 1024
    data_bytes = data_size_sectors * 512 * 2  # 2x base size for CoW overhead

    with {_, 0} <- System.cmd("truncate", ["-s", "#{metadata_bytes}", metadata_path]),
         {_, 0} <- System.cmd("truncate", ["-s", "#{data_bytes}", data_path]),
         {:ok, meta_loop} <- losetup(metadata_path),
         {:ok, data_loop} <- losetup(data_path) do
      {:ok, meta_loop, data_loop}
    else
      {err, code} -> {:error, {:pool_device_creation_failed, code, err}}
      {:error, _} = err -> err
    end
  end

  defp create_thin_pool_dm(pool_name, meta_device, data_device, size_sectors) do
    # Check if already exists
    case System.cmd("dmsetup", ["info", pool_name], stderr_to_stdout: true) do
      {_, 0} -> :ok  # Already exists, reuse it
      _ ->
        System.cmd("dd", ["if=/dev/zero", "of=#{meta_device}", "bs=4096", "count=1"], stderr_to_stdout: true)
        table = "0 #{size_sectors} thin-pool #{meta_device} #{data_device} #{@chunk_sectors} 0"
        case System.cmd("dmsetup", ["create", pool_name, "--table", table], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {err, code} -> {:error, {:thin_pool_create_failed, code, err}}
        end
    end
  end

  defp do_create_snapshot(pool_info, _thin_id, container_id) do
    pool_device = "/dev/mapper/#{pool_info.name}"
    snap_name = "zypi-snap-#{container_id}"

    # Check if snapshot already exists
    case System.cmd("dmsetup", ["info", snap_name], stderr_to_stdout: true) do
      {_, 0} ->
        {:ok, "/dev/mapper/#{snap_name}"}
      _ ->
        # Use hash of container_id for unique thin_id
        thin_id = :erlang.phash2(container_id, 1_000_000)

        with {_, 0} <- System.cmd("dmsetup", ["message", pool_device, "0", "create_thin #{thin_id}"], stderr_to_stdout: true) do
          table = "0 #{pool_info.size} thin #{pool_device} #{thin_id} #{pool_info.base}"
          case System.cmd("dmsetup", ["create", snap_name, "--table", table], stderr_to_stdout: true) do
            {_, 0} -> {:ok, "/dev/mapper/#{snap_name}"}
            {err, code} -> {:error, {:snapshot_create_failed, code, err}}
          end
        else
          {err, code} -> {:error, {:thin_create_failed, code, err}}
        end
    end
  end

  defp get_device_sectors(device) do
    # For loop devices backed by files, get size from file
    case System.cmd("blockdev", ["--getsz", device], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output |> String.trim() |> String.to_integer()}
      {err, code} -> {:error, {:blockdev_failed, code, err}}
    end
  end

  defp losetup(path) do
    case System.cmd("losetup", ["--find", "--show", path], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {err, code} -> {:error, {:losetup_failed, code, err}}
    end
  end

  defp pool_name(image_ref) do
    hash = :crypto.hash(:sha256, image_ref) |> Base.encode16(case: :lower) |> String.slice(0, 12)
    "zypi-pool-#{hash}"
  end
end
