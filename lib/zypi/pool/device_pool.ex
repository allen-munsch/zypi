defmodule Zypi.Pool.DevicePool do
  @moduledoc """
  Manages base images. Creates ext4 images from OCI layers.
  """
  use GenServer
  require Logger

  alias Zypi.Image.Delta

  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")
  @devices_dir Path.join( @data_dir, "devices")

  defstruct images: MapSet.new(), pending: MapSet.new()

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def acquire(image_ref), do: GenServer.call(__MODULE__, {:acquire, image_ref}, 30_000)
  def warm(image_ref), do: GenServer.cast(__MODULE__, {:warm, image_ref})
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_opts) do
    File.mkdir_p!(@devices_dir)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:acquire, _image_ref}, _from, state) do
    # This will be replaced by overlaybd device attachment
    {:reply, {:error, :not_implemented}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{ready: MapSet.to_list(state.images), pending: MapSet.to_list(state.pending)}, state}
  end

  @impl true
  def handle_cast({:warm, image_ref}, state) do
    cond do
      MapSet.member?(state.images, image_ref) or MapSet.member?(state.pending, image_ref) ->
        {:noreply, state}

      true ->
        state = %{state | pending: MapSet.put(state.pending, image_ref)}
        parent = self()
        Task.start(fn -> do_warm(image_ref, parent) end)
        {:noreply, state}
    end
  end

  def attach_overlaybd_device(image_ref, device_id) do
    with {:ok, manifest} <- Delta.get(image_ref),
         config = manifest.overlaybd_config do

      result_file = "/tmp/zypi-#{device_id}.img"
      
      # Update config with the dynamic result file path
      updated_config = put_in(config, ["resultFile"], result_file)
      
      temp_config_path = "/tmp/config-#{device_id}.json"
      :ok = File.write(temp_config_path, Jason.encode!(updated_config))

      # Attach the device using the temporary config
      case System.cmd("overlaybd-create", [temp_config_path]) do
        {device_path, 0} ->
          File.rm(temp_config_path)
          {:ok, String.trim(device_path)}
        {err, code} ->
          File.rm(temp_config_path)
          {:error, {:overlaybd_create_failed, code, err}}
      end
    else
      {:error, _} = error -> error
    end
  end

  @impl true
  def handle_info({:warmed, image_ref, :ok}, state) do
    Logger.info("DevicePool: Image #{image_ref} ready")
    {:noreply, %{state |
      images: MapSet.put(state.images, image_ref),
      pending: MapSet.delete(state.pending, image_ref)
    }}
  end

  @impl true
  def handle_info({:warmed, image_ref, {:error, reason}}, state) do
    Logger.error("DevicePool: Failed to warm #{image_ref}: #{inspect(reason)}")
    {:noreply, %{state | pending: MapSet.delete(state.pending, image_ref)}}
  end

  defp do_warm(image_ref, parent) do
    result =
      case Delta.get(image_ref) do
        {:ok, manifest} ->
          # Check all layer files exist
          layers_exist? = Enum.all?(manifest.overlaybd_config["lowers"], fn layer ->
            File.exists?(layer["file"])
          end)
          if layers_exist?, do: :ok, else: {:error, :layers_missing}
        error -> error
      end
    send(parent, {:warmed, image_ref, result})
  end
end
