defmodule Zypi.Container.Manager do
  @moduledoc """
  Manages container lifecycle with Firecracker VM support.
  """
  use GenServer
  require Logger

  alias Zypi.Store.Containers
  alias Zypi.Store.Containers.Container
  alias Zypi.Pool.IPPool
  alias Zypi.Runtime

  @output_buffer_size 1000

  defstruct outputs: %{}, subscribers: %{}, vm_states: %{}, port_to_container: %{}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def create(params), do: GenServer.call(__MODULE__, {:create, params}, 30_000)
  def start(container_id), do: GenServer.call(__MODULE__, {:start, container_id}, 30_000)
  def stop(container_id), do: GenServer.call(__MODULE__, {:stop, container_id}, 10_000)
  def destroy(container_id), do: GenServer.call(__MODULE__, {:destroy, container_id}, 10_000)
  def get(container_id), do: Containers.get(container_id)
  def list, do: Containers.list()

  @doc """
  Get SSH connection info for shell access.
  """
  def get_shell_info(container_id) do
    case Containers.get(container_id) do
      {:ok, container} ->
        case container.status do
          :running ->
            ssh_key = Application.get_env(:zypi, :ssh_key_path)

            if ssh_key && container.ip do
              {:ok, %{
                container_id: container_id,
                ip: format_ip(container.ip),
                ssh_key_path: ssh_key,
                ssh_user: "root",
                ssh_port: 22
              }}
            else
              {:error, :ssh_not_configured}
            end

          status ->
            {:error, {:not_running, status}}
        end

      {:error, :not_found} = error ->
        error
    end
  end

  @doc """
  Check if SSH is ready on the container.
  """
  def ssh_ready?(container_id) do
    case get_shell_info(container_id) do
      {:ok, %{ip: ip}} ->
        case :gen_tcp.connect(String.to_charlist(ip), 22, [], 2000) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            true
          {:error, _} ->
            false
        end
      _ ->
        false
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip) when is_binary(ip), do: ip

  def get_output(container_id), do: GenServer.call(__MODULE__, {:get_output, container_id})
  def subscribe(container_id), do: GenServer.call(__MODULE__, {:subscribe, container_id, self()})
  def unsubscribe(container_id), do: GenServer.cast(__MODULE__, {:unsubscribe, container_id, self()})

  @impl true
  def init(_opts) do
    # Clean up any orphaned consoles from previous Manager instances
    cleanup_orphaned_consoles()

    Logger.info("Container.Manager initialized (Firecracker runtime)")
    {:ok, %__MODULE__{}}
  end

  defp cleanup_orphaned_consoles do
    # Get all containers from store
    containers = Zypi.Store.Containers.list()
    _container_ids = Enum.map(containers, & &1.id) |> MapSet.new()

    # Find all globally registered consoles
    # :global.registered_names() returns all global names
    :global.registered_names()
    |> Enum.filter(fn
      {:zypi_console, _vm_id} -> true
      _ -> false
    end)
    |> Enum.each(fn {:zypi_console, vm_id} = name ->
      # If container doesn't exist or isn't running, stop the console
      container = Enum.find(containers, & &1.id == vm_id)

      should_stop = cond do
        is_nil(container) ->
          Logger.debug("Cleaning up orphaned console for non-existent container #{vm_id}")
          true
        container.status not in [:running, :starting] ->
          Logger.debug("Cleaning up console for non-running container #{vm_id} (status: #{container.status})")
          true
        true ->
          false
      end

      if should_stop do
        case :global.whereis_name(name) do
          :undefined -> :ok
          pid ->
            try do
              GenServer.stop(pid, :normal, 1000)
            catch
              _, _ -> :ok
            end
        end
      end
    end)
  rescue
    e -> Logger.warning("Error during console cleanup: #{inspect(e)}")
  end

  @impl true
  def handle_call({:create, params}, _from, state) do
    {:reply, do_create(params), state}
  end

  @impl true
  def handle_call({:start, id}, _from, state) do
    case do_start(id) do
      {:ok, vm_state} ->
        # Get the port from vm_state - it's called :pid not :fc_port
        fc_port = vm_state[:pid]  # The Firecracker port

        state = %{state |
          outputs: Map.put(state.outputs, id, []),
          vm_states: Map.put(state.vm_states, id, vm_state),
          port_to_container: Map.put(state.port_to_container, fc_port, id)
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

    # Clean up port mapping
    port_to_container = if vm_state && vm_state.fc_port do
      Map.delete(state.port_to_container, vm_state.fc_port)
    else
      state.port_to_container
    end

    state = %{state |
      outputs: Map.delete(state.outputs, id),
      subscribers: Map.delete(state.subscribers, id),
      vm_states: Map.delete(state.vm_states, id),
      port_to_container: port_to_container
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
  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    case Map.get(state.port_to_container, port) do
      nil ->
        Logger.debug("Unknown port exited with status #{status}")
        {:noreply, state}

      container_id ->
        Logger.info("VM #{container_id} port exited with status #{status}")
        Containers.update(container_id, %{status: :exited})

        # Notify Console and subscribers
        exit_msg = "\r\n[VM exited with status #{status}]\r\n"
        Zypi.Container.Console.forward_output(container_id, exit_msg)
        broadcast_output(state, container_id, exit_msg)

        # Clean up port mapping
        state = %{state | port_to_container: Map.delete(state.port_to_container, port)}
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    case Map.get(state.port_to_container, port) do
      nil ->
        Logger.debug("Manager received data from unknown port: #{byte_size(data)} bytes")
        {:noreply, state}

      container_id ->
        # Forward to Console GenServer for this container
        Zypi.Container.Console.forward_output(container_id, data)

        # Also maintain local buffer for logs API and subscribers
        state = buffer_output(state, container_id, data)
        broadcast_output(state, container_id, data)
        {:noreply, state}
    end
  end

  # Catch-all for other messages, if you want
  @impl true
  def handle_info(msg, state) do
    Logger.debug("Manager received unknown msg: #{inspect(msg)}")
    {:noreply, state}
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

  with {:ok, snapshot_path} <- Zypi.Pool.ImageStore.create_snapshot(image_ref, container_id),
       {:ok, ip} <- IPPool.acquire() do
    container = %Container{
      id: container_id,
      image: image_ref,
      rootfs: snapshot_path,
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
  else
    {:error, :image_not_found} ->
      Logger.error("Image not found: #{image_ref}")
      {:error, :image_not_found}
    {:error, reason} ->
      Logger.error("Create failed: #{inspect(reason)}")
      {:error, reason}
  end
end

defp do_destroy(container_id, vm_state) do
  case Containers.get(container_id) do
    {:ok, container} ->
      if container.status == :running and vm_state do
        Runtime.stop(%{container | pid: vm_state})
      end
            Runtime.cleanup(container_id)
      Zypi.Pool.ImageStore.destroy_snapshot(container_id)
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
