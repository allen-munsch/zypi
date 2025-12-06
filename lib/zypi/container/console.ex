defmodule Zypi.Container.Console do
  use GenServer
  require Logger

  @doc """
  Starts the console GenServer for a given VM.
  Called by RuntimeFirecracker when VM starts.
  """
  def start_link(vm_id, fc_port, opts \\ []) do
    # Remove any conflicting name from opts
    opts = Keyword.delete(opts, :name)
    GenServer.start_link(__MODULE__, {vm_id, fc_port}, [name: via_tuple(vm_id)] ++ opts)
  end

  @doc """
  Check if a console exists for the given VM.
  """
  def exists?(vm_id) do
    case GenServer.whereis(via_tuple(vm_id)) do
      nil -> false
      pid when is_pid(pid) -> Process.alive?(pid)
    end
  end

  @doc """
  Connects a client PID to receive console output.
  """
  def connect(vm_id, client_pid) do
    GenServer.cast(via_tuple(vm_id), {:connect, client_pid})
  end

  @doc """
  Disconnects a client PID from the console.
  """
  def disconnect(vm_id, client_pid) do
    GenServer.cast(via_tuple(vm_id), {:disconnect, client_pid})
  end

  @doc """
  Sends input to the VM via the console.
  """
  def send_input(vm_id, data) do
    GenServer.cast(via_tuple(vm_id), {:input, data})
  end

  @doc """
  Retrieves the buffered output for a VM.
  """
  def get_output(vm_id) do
    GenServer.call(via_tuple(vm_id), :get_output)
  catch
    :exit, _ -> ""
  end

  @doc """
  Stops the console GenServer.
  """
  def stop(vm_id) do
    case GenServer.whereis(via_tuple(vm_id)) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5000)
    end
  catch
    :exit, _ -> :ok
  end

  # Internal function to get the GenServer name
  defp via_tuple(vm_id), do: {:global, {:zypi_console, vm_id}}

  @impl true
  def init({vm_id, fc_port}) do
    Logger.info("Console started for VM #{vm_id}")
    {:ok, %{
      vm_id: vm_id,
      fc_port: fc_port,
      clients: [],
      buffer: ""
    }}
  end

  @impl true
  def handle_cast({:connect, client_pid}, state) do
    Logger.debug("Console #{state.vm_id}: Client #{inspect(client_pid)} connected")
    Process.monitor(client_pid)
    {:noreply, %{state | clients: [client_pid | state.clients]}}
  end

  @impl true
  def handle_cast({:disconnect, client_pid}, state) do
    Logger.debug("Console #{state.vm_id}: Client #{inspect(client_pid)} disconnected")
    {:noreply, %{state | clients: List.delete(state.clients, client_pid)}}
  end

  @impl true
  def handle_cast({:input, data}, state) do
    # Send input to Firecracker's stdin via the port
    if is_port(state.fc_port) and Port.info(state.fc_port) != nil do
      try do
        Port.command(state.fc_port, data)
      catch
        :error, :badarg -> Logger.warning("Console #{state.vm_id}: Port closed, cannot send input")
      end
    end
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_output, _from, state) do
    {:reply, state.buffer, state}
  end

  @impl true
  def handle_info({:vm_output, data}, state) do
    # Append to buffer (keep last 64KB)
    new_buffer = state.buffer <> data
    buffer = if byte_size(new_buffer) > 65_536 do
      binary_part(new_buffer, byte_size(new_buffer) - 65_536, 65_536)
    else
      new_buffer
    end

    # Broadcast to all connected clients
    for client <- state.clients do
      send(client, {:console_output, data})
    end

    {:noreply, %{state | buffer: buffer}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, client_pid, _reason}, state) do
    Logger.debug("Console #{state.vm_id}: Client #{inspect(client_pid)} went down")
    {:noreply, %{state | clients: List.delete(state.clients, client_pid)}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Console #{state.vm_id}: Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
end