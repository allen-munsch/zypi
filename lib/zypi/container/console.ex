defmodule Zypi.Container.Console do
  @moduledoc """
  Console manager for VM serial output/input.
  """
  use GenServer
  require Logger

  # Client API
  def start_link(vm_id, socket_path) do
    GenServer.start_link(__MODULE__, {vm_id, socket_path}, name: via_tuple(vm_id))
  end

  def connect(vm_id, pid) do
    GenServer.cast(via_tuple(vm_id), {:connect, pid})
  end

  def disconnect(vm_id, pid) do
    GenServer.cast(via_tuple(vm_id), {:disconnect, pid})
  end

  def send_input(vm_id, data) do
    GenServer.cast(via_tuple(vm_id), {:input, data})
  end

  def get_output(vm_id) do
    GenServer.call(via_tuple(vm_id), :get_output)
  end

  defp via_tuple(vm_id), do: {:via, Registry, {Zypi.Container.Registry, "console:#{vm_id}"}}

  # Server implementation
  def init({vm_id, socket_path}) do
    {:ok, %{
      vm_id: vm_id,
      socket_path: socket_path,
      clients: [],
      buffer: "",
      reader_pid: nil
    }, {:continue, :setup_monitor}}
  end

  def handle_continue(:setup_monitor, state) do
    # Start monitoring the serial socket
    reader_pid = spawn_link(fn -> read_serial(state.socket_path, state.vm_id) end)
    {:noreply, %{state | reader_pid: reader_pid}}
  end

  def handle_cast({:connect, pid}, state) do
    Process.monitor(pid)
    send(pid, {:console_output, "Connected to console for #{state.vm_id}\r\n"})
    {:noreply, %{state | clients: [pid | state.clients]}}
  end

  def handle_cast({:disconnect, pid}, state) do
    {:noreply, %{state | clients: List.delete(state.clients, pid)}}
  end

  def handle_cast({:input, data}, state) do
    # Send input to VM via the serial socket
    case File.open(Path.join(Path.dirname(state.socket_path), "serial.in"), [:write, :append]) do
      {:ok, fd} ->
        IO.binwrite(fd, data)
        File.close(fd)
      _ ->
        Logger.error("Failed to write input to VM #{state.vm_id}")
    end
    {:noreply, state}
  end

  def handle_call(:get_output, _from, state) do
    {:reply, state.buffer, state}
  end

  def handle_info({:serial_output, data}, state) do
    # Broadcast to all connected clients
    for client <- state.clients do
      send(client, {:console_output, data})
    end

    # Keep last 10KB of buffer
    new_buffer = state.buffer <> data
    buffer = if byte_size(new_buffer) > 10000 do
      binary_part(new_buffer, byte_size(new_buffer) - 10000, 10000)
    else
      new_buffer
    end

    {:noreply, %{state | buffer: buffer}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | clients: List.delete(state.clients, pid)}}
  end

  defp read_serial(socket_path, vm_id) do
    vm_path = Path.dirname(socket_path)
    serial_path = Path.join(vm_path, "serial.log")

    # Configure serial console in Firecracker
    configure_serial(socket_path)

    # Tail the serial log file
    if File.exists?(serial_path) do
      tail_file(serial_path, vm_id)
    else
      # Fallback: read from stderr of firecracker process
      Process.sleep(1000)
      read_serial(socket_path, vm_id)
    end
  end

  defp configure_serial(socket_path) do
    # Configure serial device in Firecracker
    config = %{
      "type" => "serial",
      "iommu" => false,
      "num" => 0
    }

    # You might need to add this to your configure_vm function
    # For now, we'll just ensure the boot args include console=ttyS0
    # (which you already have)
    Logger.debug("Configuring serial for #{socket_path}")
  end

  defp tail_file(path, vm_id) do
    # Use File.stream! to tail the file
    stream = File.stream!(path, [], :line)

    for line <- stream do
      pid = Process.whereis(via_tuple(vm_id))
      if pid do
        send(pid, {:serial_output, line})
      end
    end
  rescue
    _e ->
      Process.sleep(100)
      tail_file(path, vm_id)
  end
end
