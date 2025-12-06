defmodule Zypi.API.ConsoleSocket do
  use GenServer
  require Logger

  alias Zypi.Container.Console

  @port 4001

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def get_port, do: @port

  @impl true
  def init(_args) do
    # Start listening socket
    {:ok, listen_socket} = :gen_tcp.listen(@port, [
      :binary,
      active: false,
      reuseaddr: true,
      packet: :line,  # Changed: line-based for initial handshake
      exit_on_close: false
    ])
    Logger.info("Console socket listening on port #{@port}")
    
    # CRITICAL FIX: Start the accept loop
    {:ok, %{listen_socket: listen_socket}, {:continue, :accept_loop}}
  end

  @impl true
  def handle_continue(:accept_loop, state) do
    # Spawn acceptor task to not block GenServer
    Task.start_link(fn -> accept_loop(state.listen_socket) end)
    {:noreply, state}
  end

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_socket} ->
        # Spawn handler for this client
        spawn(fn -> handle_client(client_socket) end)
        # Continue accepting
        accept_loop(listen_socket)
      {:error, :closed} ->
        Logger.info("Console listen socket closed")
      {:error, reason} ->
        Logger.error("Console accept error: #{inspect(reason)}")
    end
  end

  defp handle_client(client_socket) do
    # Read the ATTACH:<vm_id> line
    case :gen_tcp.recv(client_socket, 0, 10_000) do
      {:ok, data} ->
        case parse_attach_command(String.trim(data)) do
          {:ok, vm_id} ->
            attach_to_console(client_socket, vm_id)
          :error ->
            :gen_tcp.send(client_socket, "ERROR: Expected ATTACH:<container_id>\r\n")
            :gen_tcp.close(client_socket)
        end
      {:error, reason} ->
        Logger.debug("Console handshake failed: #{inspect(reason)}")
        :gen_tcp.close(client_socket)
    end
  end

  defp parse_attach_command("ATTACH:" <> vm_id), do: {:ok, vm_id}
  defp parse_attach_command(_), do: :error

  defp attach_to_console(client_socket, vm_id) do
    # Check if console exists for this VM
    case Console.exists?(vm_id) do
      true ->
        Logger.info("Client attaching to console for VM: #{vm_id}")
        
        # Send initial buffered output
        buffered = Console.get_output(vm_id)
        if buffered != "", do: :gen_tcp.send(client_socket, buffered)
        
        # Switch to raw mode for bidirectional streaming
        :inet.setopts(client_socket, [packet: :raw, active: true])
        
        # Register this client with the Console
        Console.connect(vm_id, self())
        
        :gen_tcp.send(client_socket, "\r\n--- Connected to #{vm_id} ---\r\n")
        
        # Enter the relay loop
        client_relay_loop(client_socket, vm_id)
        
      false ->
        :gen_tcp.send(client_socket, "ERROR: No console for container #{vm_id}\r\n")
        :gen_tcp.close(client_socket)
    end
  end

  defp client_relay_loop(client_socket, vm_id) do
    receive do
      # Output from VM Console → send to TCP client
      {:console_output, data} ->
        case :gen_tcp.send(client_socket, data) do
          :ok -> client_relay_loop(client_socket, vm_id)
          {:error, _} -> cleanup_client(vm_id)
        end

      # Input from TCP client → send to VM Console
      {:tcp, ^client_socket, data} ->
        Console.send_input(vm_id, data)
        client_relay_loop(client_socket, vm_id)

      # Client disconnected
      {:tcp_closed, ^client_socket} ->
        Logger.info("Console client disconnected from #{vm_id}")
        cleanup_client(vm_id)

      {:tcp_error, ^client_socket, reason} ->
        Logger.debug("Console client error: #{inspect(reason)}")
        cleanup_client(vm_id)

    after
      60_000 ->
        # Keepalive - just continue
        client_relay_loop(client_socket, vm_id)
    end
  end

  defp cleanup_client(vm_id) do
    Console.disconnect(vm_id, self())
    :ok
  end

  @impl true
  def terminate(_reason, %{listen_socket: listen_socket}) do
    :gen_tcp.close(listen_socket)
    :ok
  end
end
