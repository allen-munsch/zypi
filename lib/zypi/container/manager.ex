defmodule Zypi.Container.Manager do
  @moduledoc """
  Manages container lifecycle with output capture and attach support.
  """
  use GenServer
  require Logger

  alias Zypi.Store.Containers
  alias Zypi.Store.Containers.Container
  alias Zypi.Pool.{DevicePool, ThinPool, IPPool}
  alias Zypi.Container.Runtime

  @output_buffer_size 1000

  defstruct outputs: %{}, subscribers: %{}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def create(params), do: GenServer.call(__MODULE__, {:create, params}, 10_000)
  def start(container_id), do: GenServer.call(__MODULE__, {:start, container_id}, 10_000)
  def stop(container_id), do: GenServer.call(__MODULE__, {:stop, container_id}, 10_000)
  def destroy(container_id), do: GenServer.call(__MODULE__, {:destroy, container_id}, 10_000)
  def get(container_id), do: Containers.get(container_id)
  def list, do: Containers.list()

  def get_output(container_id), do: GenServer.call(__MODULE__, {:get_output, container_id})
  def subscribe(container_id), do: GenServer.call(__MODULE__, {:subscribe, container_id, self()})
  def unsubscribe(container_id), do: GenServer.cast(__MODULE__, {:unsubscribe, container_id, self()})

  @impl true
  def init(_opts) do
    Logger.info("Zypi.Container.Manager initialized")
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:create, params}, _from, state) do
    {:reply, do_create(params), state}
  end

  @impl true
  def handle_call({:start, id}, _from, state) do
    case do_start(id) do
      {:ok, _port} ->
        state = %{state | outputs: Map.put(state.outputs, id, [])}
        {:reply, {:ok, id}, state}
      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:stop, id}, _from, state) do
    result = do_stop(id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:destroy, id}, _from, state) do
    result = do_destroy(id)
    state = %{state |
      outputs: Map.delete(state.outputs, id),
      subscribers: Map.delete(state.subscribers, id)
    }
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_output, id}, _from, state) do
    output = Map.get(state.outputs, id, []) |> Enum.reverse() |> Enum.join()
    {:reply, {:ok, output}, state}
  end

  @impl true
  def handle_call({:subscribe, id, pid}, _from, state) do
    subs = Map.get(state.subscribers, id, [])
    state = %{state | subscribers: Map.put(state.subscribers, id, [pid | subs])}
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:unsubscribe, id, pid}, state) do
    subs = Map.get(state.subscribers, id, []) |> Enum.reject(&(&1 == pid))
    state = %{state | subscribers: Map.put(state.subscribers, id, subs)}
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    case find_container_by_port(port) do
      {:ok, container_id} ->
        state = buffer_output(state, container_id, data)
        broadcast_output(state, container_id, data)
        {:noreply, state}
      :not_found ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    case find_container_by_port(port) do
      {:ok, container_id} ->
        Logger.info("Container #{container_id} exited with status #{status}")
        Containers.update(container_id, %{status: :exited, pid: nil})
        broadcast_output(state, container_id, "\n[Process exited with status #{status}]\n")
        {:noreply, state}
      :not_found ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Container.Manager received: #{inspect(msg)}")
    {:noreply, state}
  end

  defp do_create(params) do
    container_id = params[:id] || generate_id()
    image_ref = params[:image]
    start_us = System.monotonic_time(:microsecond)

    with {:ok, _base_device} <- DevicePool.acquire(image_ref),
         {:ok, snapshot} <- ThinPool.create_snapshot(image_ref, container_id),
         {:ok, ip} <- IPPool.acquire() do

      container = %Container{
        id: container_id,
        image: image_ref,
        rootfs: snapshot,
        ip: ip,
        status: :created,
        created_at: DateTime.utc_now(),
        resources: params[:resources] || %{cpu: 1, memory_mb: 256},
        metadata: params[:metadata] || %{}
      }

      Containers.put(container)
      elapsed_us = System.monotonic_time(:microsecond) - start_us
      Logger.info("Container #{container_id} created in #{elapsed_us}µs")
      {:ok, container}
    else
      {:error, :pool_empty} ->
        Logger.warning("Device pool empty for #{image_ref}, triggering warm")
        DevicePool.warm(image_ref)
        {:error, :image_not_ready}
      {:error, reason} = error ->
        Logger.error("Container create failed: #{inspect(reason)}")
        error
    end
  end
  defp do_start(container_id) do
    case Containers.get(container_id) do
      {:ok, %{status: :running}} ->
        {:error, :already_running}
      {:ok, container} ->
        case Runtime.start(container) do
          {:ok, pid} when is_integer(pid) or is_binary(pid) ->
            Containers.update(container_id, %{status: :running, started_at: DateTime.utc_now()})
            Logger.info("Container #{container_id} started with PID: #{pid}")
            {:ok, pid}
          {:ok, port} when is_port(port) ->
            Containers.update(container_id, %{status: :running, started_at: DateTime.utc_now(), pid: port})
            Logger.info("Container #{container_id} started with port: #{inspect(port)}")
            {:ok, port}
          {:error, reason} ->
            Logger.error("Failed to start container #{container_id}: #{inspect(reason)}")
            {:error, reason}
          other ->
            Logger.error("Unexpected result from Runtime.start: #{inspect(other)}")
            {:error, :runtime_error}
        end
      error ->
        error
    end
  end

  defp do_stop(container_id) do
    case Containers.get(container_id) do
      {:ok, %{status: :exited}} ->
        {:ok, container_id}
      {:ok, %{pid: port} = container} when not is_nil(port) ->
        Runtime.stop(container)
        Containers.update(container_id, %{status: :stopped, pid: nil})
        {:ok, container_id}
      {:ok, %{status: status}} when status in [:stopped, :created] ->
        {:ok, container_id}
      {:ok, _} ->
        {:error, :not_running}
      error ->
        error
    end
  end

  defp do_destroy(container_id) do
    case Containers.get(container_id) do
      {:ok, container} ->
        if container.status == :running, do: Runtime.stop(container)
        Runtime.cleanup_rootfs(container_id)
        ThinPool.destroy_snapshot(container.image, container_id)
        if container.ip, do: IPPool.release(container.ip)
        Containers.delete(container_id)
        {:ok, container_id}
      error ->
        error
    end
  end

  defp find_container_by_port(port) do
    case Enum.find(Containers.list(), fn c -> c.pid == port end) do
      nil -> :not_found
      container -> {:ok, container.id}
    end
  end

  defp buffer_output(state, container_id, data) do
    buffer = Map.get(state.outputs, container_id, [])
    buffer = [data | buffer] |> Enum.take(@output_buffer_size)
    %{state | outputs: Map.put(state.outputs, container_id, buffer)}
  end

  defp broadcast_output(state, container_id, data) do
    subs = Map.get(state.subscribers, container_id, [])
    Enum.each(subs, fn pid ->
      if Process.alive?(pid), do: send(pid, {:container_output, container_id, data})
    end)
  end

  defp generate_id do
    "ctr_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
