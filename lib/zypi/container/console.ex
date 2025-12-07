defmodule Zypi.Container.Console do
  use GenServer
  require Logger

  @doc """
  Starts the console GenServer for a given VM.
  Called by RuntimeFirecracker when VM starts.
  """
  def start_link(vm_id, fc_port, opts \\ []) do
    opts = Keyword.delete(opts, :name)
    
    case GenServer.whereis(via_tuple(vm_id)) do
      nil ->
        # No existing process, start fresh
        GenServer.start_link(__MODULE__, {vm_id, fc_port}, [name: via_tuple(vm_id)] ++ opts)
        
      existing_pid ->
        # Process exists - check if it's alive
        if Process.alive?(existing_pid) do
          {:error, {:already_started, existing_pid}}
        else
          # Process registered but dead (shouldn't happen with :global, but be safe)
          # Unregister and start fresh
          :global.unregister_name({:zypi_console, vm_id})
          GenServer.start_link(__MODULE__, {vm_id, fc_port}, [name: via_tuple(vm_id)] ++ opts)
        end
    end
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
  Get a fresh shell prompt in the VM console.
  The shell is always running - just send newline to get prompt.
  """
  def spawn_shell(vm_id) do
    case exists?(vm_id) do
      true ->
        # Send a couple newlines to get a fresh prompt
        send_input(vm_id, "\n\n")
        :ok
      false ->
        {:error, :console_not_found}
    end
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
  Forward output from the VM to connected clients.
  Called by Manager which owns the Firecracker port.
  """
  def forward_output(vm_id, data) do
    case GenServer.whereis(via_tuple(vm_id)) do
      nil -> 
        # Console not running yet, data will be lost
        # This is fine during early boot before console starts
        :ok
      _pid -> 
        GenServer.cast(via_tuple(vm_id), {:vm_output_from_manager, data})
    end
  end

  @doc """
  Stops the console GenServer.
  """
   @doc """
Stops the console GenServer. Safe to call even if console doesn't exist.
"""
def stop(vm_id) do
  case GenServer.whereis(via_tuple(vm_id)) do
    nil -> 
      :ok
    pid -> 
      try do
        GenServer.stop(pid, :normal, 5000)
      catch
        :exit, {:noproc, _} -> :ok
        :exit, {:normal, _} -> :ok
        :exit, _ -> :ok
      end
  end
end

 @doc """
Restarts the console with a new Firecracker port.
Stops existing console if present, then starts fresh.
"""
def restart(vm_id, fc_port) do
  stop(vm_id)
  Process.sleep(50)  # Allow cleanup to complete
  start_link(vm_id, fc_port)
end

  @doc """
  Clear the console buffer.
  Useful when starting a shell session to not show boot history.
  """
  def clear_buffer(vm_id) do
    GenServer.cast(via_tuple(vm_id), :clear_buffer)
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
  def handle_cast({:vm_output_from_manager, data}, state) do
    # Append to buffer (keep last 64KB for more history)
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
  def handle_cast(:clear_buffer, state) do
    {:noreply, %{state | buffer: ""}}
  end

  @impl true
  def handle_call(:get_output, _from, state) do
    {:reply, state.buffer, state}
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