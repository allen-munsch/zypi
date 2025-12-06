defmodule Zypi.Container.Manager do
  @moduledoc """
  Manages container lifecycle with Firecracker VM support.
  """
  use GenServer
  require Logger

  alias Zypi.Store.Containers
  alias Zypi.Store.Containers.Container
  alias Zypi.Pool.{DevicePool, IPPool}
  alias Zypi.Container.Runtime

  @output_buffer_size 1000

  defstruct outputs: %{}, subscribers: %{}, vm_states: %{}, buffer: ""

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def create(params), do: GenServer.call(__MODULE__, {:create, params}, 30_000)
  def start(container_id), do: GenServer.call(__MODULE__, {:start, container_id}, 30_000)
  def stop(container_id), do: GenServer.call(__MODULE__, {:stop, container_id}, 10_000)
  def destroy(container_id), do: GenServer.call(__MODULE__, {:destroy, container_id}, 10_000)
  def get(container_id), do: Containers.get(container_id)
  def list, do: Containers.list()

  def get_output(container_id), do: GenServer.call(__MODULE__, {:get_output, container_id})
  def subscribe(container_id), do: GenServer.call(__MODULE__, {:subscribe, container_id, self()})
  def unsubscribe(container_id), do: GenServer.cast(__MODULE__, {:unsubscribe, container_id, self()})

  @impl true
  def init(_opts) do
    Logger.info("Container.Manager initialized (Firecracker runtime)")
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:create, params}, _from, state) do
    {:reply, do_create(params), state}
  end

  @impl true
  def handle_call({:start, id}, _from, state) do
    case do_start(id) do
      {:ok, vm_state} ->
        state = %{state |
          outputs: Map.put(state.outputs, id, []),
          vm_states: Map.put(state.vm_states, id, vm_state)
        }
        {:reply, {:ok, id}, state}
      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:stop, id}, _from, state) do
    vm_state = Map.get(state.vm_states, id)
    result = do_stop(id, vm_state)
    state = %{state | vm_states: Map.delete(state.vm_states, id)}
    {:reply, result, state}
  end

  @impl true
  def handle_call({:destroy, id}, _from, state) do
    vm_state = Map.get(state.vm_states, id)
    result = do_destroy(id, vm_state)
    state = %{state |
      outputs: Map.delete(state.outputs, id),
      subscribers: Map.delete(state.subscribers, id),
      vm_states: Map.delete(state.vm_states, id)
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
  def handle_info({:vm_output, container_id, data}, state) do
    # Log the VM output line by line
    data
    |> String.split("\n", trim: true)
    |> Enum.each(fn line ->
      Logger.debug("VM #{container_id}: #{line}")
    end)

    state = buffer_output(state, container_id, data)
    broadcast_output(state, container_id, data)
    {:noreply, state}
  end

  @impl true
  def handle_info({:vm_exited, container_id, status}, state) do
    Logger.info("VM #{container_id} exited with status #{status}")
    Containers.update(container_id, %{status: :exited})
    broadcast_output(state, container_id, "\n[VM exited with status #{status}]\n")
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{buffer: buffer} = state) when is_port(port) do
    # 'data' is already a string/binary
    new_buffer = buffer <> data

    {lines, remainder} = split_lines(new_buffer)

    Enum.each(lines, fn line ->
      Logger.debug("Manager received line: #{line}")
    end)

    {:noreply, %{state | buffer: remainder}}
  end

  # Catch-all for other messages, if you want
  @impl true
  def handle_info(msg, state) do
    Logger.debug("Manager received unknown msg: #{inspect(msg)}")
    {:noreply, state}
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\r\n", trim: false)
    lines = Enum.drop(parts, -1)       # all complete lines
    remainder = List.last(parts) || "" # incomplete line
    {lines, remainder}
  end

  # defp do_create(params) do
  #   container_id = params[:id] || generate_id()
  #   image_ref = params[:image]
  #   start_us = System.monotonic_time(:microsecond)

  #   with {:ok, _device} <- DevicePool.acquire(image_ref),
  #        {:ok, snapshot} <- ThinPool.create_snapshot(image_ref, container_id),
  #        {:ok, ip} <- IPPool.acquire() do

  #     container = %Container{
  #       id: container_id,
  #       image: image_ref,
  #       rootfs: snapshot,
  #       ip: ip,
  #       status: :created,
  #       created_at: DateTime.utc_now(),
  #       resources: params[:resources] || %{cpu: 1, memory_mb: 128},
  #       metadata: params[:metadata] || %{}
  #     }

  #     Containers.put(container)
  #     elapsed = System.monotonic_time(:microsecond) - start_us
  #     Logger.info("Container #{container_id} created in #{elapsed}µs")
  #     {:ok, container}
  #   else
  #     {:error, :pool_empty} ->
  #       Logger.warning("Device pool empty for #{image_ref}, warming")
  #       DevicePool.warm(image_ref)
  #       {:error, :image_not_ready}
  #     {:error, reason} = err ->
  #       Logger.error("Create failed: #{inspect(reason)}")
  #       err
  #   end
  # end

  defp do_start(container_id) do
    case Containers.get(container_id) do
      {:ok, %{status: :running}} ->
        {:error, :already_running}
      {:ok, container} ->
        case Runtime.start(container) do
          {:ok, vm_state} ->
            Containers.update(container_id, %{status: :running, started_at: DateTime.utc_now()})
            Logger.info("Container #{container_id} started as Firecracker VM")
            {:ok, vm_state}
          {:error, reason} ->
            Logger.error("Start failed: #{inspect(reason)}")
            {:error, reason}
        end
      error -> error
    end
  end

  defp do_create(params) do
    container_id = params[:id] || generate_id()
    image_ref = params[:image]
    start_us = System.monotonic_time(:microsecond)

    base_image = DevicePool.image_path(image_ref)

    # Ensure image is ready
    result = case DevicePool.acquire(image_ref) do
      {:ok, path} -> {:ok, path}
      {:error, :pool_empty} ->
        Logger.info("Image not ready, warming...")
        DevicePool.warm(image_ref)
        # Wait for warming (with timeout)
        wait_for_image(image_ref, 30_000)
    end

    case result do
      {:ok, base_path} ->
        # Create snapshot for this container
        case Zypi.Pool.SnapshotPool.create_snapshot(image_ref, container_id, base_path) do
          {:ok, snapshot_device} ->
            with {:ok, ip} <- IPPool.acquire() do
              container = %Container{
                id: container_id,
                image: image_ref,
                rootfs: snapshot_device,
                ip: ip,
                status: :created,
                created_at: DateTime.utc_now(),
                resources: params[:resources] || %{cpu: 1, memory_mb: 128},
                metadata: params[:metadata] || %{}
              }

              Containers.put(container)
              elapsed = System.monotonic_time(:microsecond) - start_us
              Logger.info("Container #{container_id} created in #{elapsed}µs")
              {:ok, container}
            end

          {:error, reason} ->
            Logger.error("Failed to create snapshot: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, :timeout} ->
        {:error, :image_not_ready}
    end
  end

  defp wait_for_image(image_ref, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_image(image_ref, deadline)
  end

  defp do_wait_for_image(image_ref, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case DevicePool.acquire(image_ref) do
        {:ok, path} -> {:ok, path}
        {:error, :pool_empty} ->
          Process.sleep(500)
          do_wait_for_image(image_ref, deadline)
      end
    end
  end

  defp do_destroy(container_id, vm_state) do
    case Containers.get(container_id) do
      {:ok, container} ->
        if container.status == :running and vm_state do
          Runtime.stop(%{container | pid: vm_state})
        end
        Runtime.cleanup_rootfs(container_id)
        Zypi.Pool.SnapshotPool.destroy_snapshot(container.image, container_id)
        if container.ip, do: IPPool.release(container.ip)
        Containers.delete(container_id)
        {:ok, container_id}
      error -> error
    end
  end

  defp do_stop(container_id, vm_state) do
    case Containers.get(container_id) do
      {:ok, %{status: status}} when status in [:exited, :stopped, :created] ->
        {:ok, container_id}
      {:ok, container} ->
        if vm_state, do: Runtime.stop(%{container | pid: vm_state})
        Containers.update(container_id, %{status: :stopped})
        {:ok, container_id}
      error -> error
    end
  end

  # defp do_destroy(container_id, vm_state) do
  #   case Containers.get(container_id) do
  #     {:ok, container} ->
  #       if container.status == :running and vm_state do
  #         Runtime.stop(%{container | pid: vm_state})
  #       end
  #       Runtime.cleanup_rootfs(container_id)
  #       ThinPool.destroy_snapshot(container.image, container_id)
  #       if container.ip, do: IPPool.release(container.ip)
  #       Containers.delete(container_id)
  #       {:ok, container_id}
  #     error -> error
  #   end
  # end

  defp buffer_output(state, container_id, data) do
    buffer = Map.get(state.outputs, container_id, [])
    buffer = [data | buffer] |> Enum.take( @output_buffer_size)
    %{state | outputs: Map.put(state.outputs, container_id, buffer)}
  end

  defp broadcast_output(state, container_id, data) do
    subs = Map.get(state.subscribers, container_id, [])
    Enum.each(subs, fn pid ->
      if Process.alive?(pid), do: send(pid, {:container_output, container_id, data})
    end)
  end

  defp generate_id, do: "ctr_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
end
