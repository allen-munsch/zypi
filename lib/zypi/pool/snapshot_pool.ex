defmodule Zypi.Pool.SnapshotPool do
  @moduledoc """
  Simple file-based CoW snapshots using cp --reflink.
  Falls back to regular copy if reflink not supported.
  """
  use GenServer
  require Logger

  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")
  @containers_dir Path.join(@data_dir, "containers")

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def create_snapshot(image_ref, container_id) do
    GenServer.call(__MODULE__, {:snapshot, image_ref, container_id}, 60_000)
  end

  def destroy_snapshot(container_id) do
    GenServer.call(__MODULE__, {:destroy, container_id})
  end

  @impl true
  def init(_opts) do
    File.mkdir_p!(@containers_dir)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:snapshot, image_ref, container_id}, _from, state) do
    # Get base config from the image delta
    case Zypi.Image.Delta.get(image_ref) do
      {:ok, manifest} ->
        base_config = manifest.overlaybd_config

        # Create a directory for the container's writable layer
        upper_dir = Path.join(@containers_dir, container_id)
        File.mkdir_p!(upper_dir)
        
        # Define the path for the writable upper layer
        upper_file = Path.join(upper_dir, "upper.tar")

        # Create an empty 10G upper layer for COW data
        case System.cmd("overlaybd-create", ["--size", "10G", "--output", upper_file]) do
          {_, 0} ->
            # Build the final snapshot config, combining base layers and the new upper
            snapshot_config = %{
              "lowers" => base_config["lowers"],
              "upper" => %{"file" => upper_file},
              "resultFile" => "/tmp/zypi-snap-#{container_id}.img"
            }

            config_path = Path.join(upper_dir, "config.json")
            File.write!(config_path, Jason.encode!(snapshot_config))

            # Attach the snapshot device using the new config
            case System.cmd("overlaybd-create", [config_path]) do
              {device, 0} ->
                device_path = String.trim(device)
                File.write!(Path.join(upper_dir, "device.path"), device_path) # Store for deletion
                {:reply, {:ok, device_path}, state}
              {err, code} ->
                {:reply, {:error, {:snapshot_attach_failed, code, err}}, state}
            end
            
          {err, code} ->
            {:reply, {:error, {:upper_create_failed, code, err}}, state}
        end
      {:error, :not_found} ->
        {:reply, {:error, :image_not_found}, state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:destroy, container_id}, _from, state) do
    container_dir = Path.join(@containers_dir, container_id)
    device_path_file = Path.join(container_dir, "device.path")

    if File.exists?(device_path_file) do
      device_path = File.read!(device_path_file)
      System.cmd("overlaybd-detach", [device_path])
    end

    File.rm_rf(container_dir)
    Logger.info("SnapshotPool: Destroyed #{container_id}")
    {:reply, :ok, state}
  end
end
