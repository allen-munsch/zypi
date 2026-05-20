defmodule Zypi.Container.Agent do
  @moduledoc """
  Client for communicating with the zypi-agent running inside VMs.
  """

  require Logger

  @tcp_port 9999
  @connect_timeout 5_000
  @call_timeout 60_000
  @health_check_interval 1_000

  defmodule Result do
    @moduledoc "Result of a command execution"
    defstruct [:exit_code, :stdout, :stderr, :signal, :timed_out]
  end

  @doc """
  Execute a command in the VM.

  Options:
    - :env - Environment variables map
    - :workdir - Working directory
    - :stdin - Standard input
    - :timeout - Command timeout in seconds
    - :ip - Explicit IP address (bypasses container lookup)
    - :host - Explicit host (for port forwarding)
    - :port - Explicit port (defaults to 9999)
  """
  def exec(container_id, cmd, opts \\ []) when is_list(cmd) do
    params = %{
      cmd: cmd,
      env: Keyword.get(opts, :env, %{}),
      workdir: Keyword.get(opts, :workdir),
      stdin: Keyword.get(opts, :stdin),
      timeout: Keyword.get(opts, :timeout, 60)
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()

    # Forward connection options (ip, host, port) to call
    call_opts = Keyword.take(opts, [:ip, :host, :port, :timeout])

    Logger.debug("Agent.exec: container_id=#{container_id}, cmd=#{inspect(cmd)}, call_opts=#{inspect(call_opts)}")

    case call(container_id, "exec", params, call_opts) do
      {:ok, result} ->
        {:ok, %Result{
          exit_code: result["exit_code"],
          stdout: result["stdout"],
          stderr: result["stderr"],
          signal: result["signal"],
          timed_out: result["timed_out"]
        }}
      error -> error
    end
  end

  @doc """
  Execute a shell command (wraps in /bin/sh -c).
  """
  def shell(container_id, command, opts \\ []) when is_binary(command) do
    exec(container_id, ["/bin/sh", "-c", command], opts)
  end

  @doc """
  Write a file to the VM.
  """
  def write_file(container_id, path, content, opts \\ []) do
    params = %{
      path: path,
      content: Base.encode64(content),
      mode: Keyword.get(opts, :mode, 0o644)
    }

    call_opts = Keyword.take(opts, [:ip, :host, :port])

    case call(container_id, "file.write", params, call_opts) do
      {:ok, %{"written" => bytes}} -> {:ok, bytes}
      error -> error
    end
  end

  @doc """
  Read a file from the VM.
  """
  def read_file(container_id, path, opts \\ []) do
    call_opts = Keyword.take(opts, [:ip, :host, :port])

    case call(container_id, "file.read", %{path: path}, call_opts) do
      {:ok, %{"content" => b64, "size" => size, "mode" => mode}} ->
        {:ok, Base.decode64!(b64), %{size: size, mode: mode}}
      {:ok, %{"content" => b64}} ->
        {:ok, Base.decode64!(b64), %{}}
      error -> error
    end
  end

  @doc """
  Health check the agent.
  """
  def health(container_id, opts \\ []) do
    call_opts = Keyword.take(opts, [:ip, :host, :port])
    call(container_id, "health", %{}, call_opts)
  end

  @doc """
  Request clean shutdown.
  """
  def shutdown(container_id, opts \\ []) do
    call_opts = Keyword.take(opts, [:ip, :host, :port])
    call(container_id, "shutdown", %{}, call_opts)
  end

  @doc """
  Wait for the agent to become healthy.
  """
  def wait_ready(container_id, timeout_ms \\ 30_000, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_ready(container_id, deadline, opts)
  end

  defp do_wait_ready(container_id, deadline, opts) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      case health(container_id, opts) do
        {:ok, %{"status" => "healthy"}} ->
          :ok
        _ ->
          Process.sleep(@health_check_interval)
          do_wait_ready(container_id, deadline, opts)
      end
    end
  end

  @doc """
  Make an RPC call to the agent.

  Options:
    - :ip - Explicit IP address tuple or string
    - :host - Explicit hostname/IP string
    - :port - Port number (default 9999)
    - :timeout - Call timeout in ms
  """
  def call(container_id, method, params, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @call_timeout)
    explicit_ip = Keyword.get(opts, :ip)
    host = Keyword.get(opts, :host)
    port = Keyword.get(opts, :port, @tcp_port)

    Logger.debug("Agent.call: method=#{method}, ip=#{inspect(explicit_ip)}, host=#{inspect(host)}")

    with {:ok, conn} <- connect(container_id, explicit_ip, host, port),
         {:ok, response} <- do_call(conn, method, params, timeout) do
      :gen_tcp.close(conn)

      case response do
        %{"error" => %{"code" => code, "message" => msg}} ->
          {:error, {:rpc_error, code, msg}}
        %{"result" => result} ->
          {:ok, result}
        other ->
          {:error, {:unexpected_response, other}}
      end
    end
  end

  @doc """
  Make an RPC call with explicit host/port (for QEMU port forwarding).
  """
  def call_with_host(_container_id, method, params, opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)
    timeout = Keyword.get(opts, :timeout, @call_timeout)

    case :gen_tcp.connect(String.to_charlist(host), port, [
           :binary,
           active: false,
           packet: :line
         ], @connect_timeout) do
      {:ok, conn} ->
        result = do_call(conn, method, params, timeout)
        :gen_tcp.close(conn)

        case result do
          {:ok, %{"error" => %{"code" => code, "message" => msg}}} ->
            {:error, {:rpc_error, code, msg}}
          {:ok, %{"result" => result}} ->
            {:ok, result}
          {:ok, other} ->
            {:error, {:unexpected_response, other}}
          error ->
            error
        end
      error ->
        error
    end
  end

  # Connect to the agent, using explicit IP/host if provided
  defp connect(container_id, explicit_ip, explicit_host, port) do
    ip_str = cond do
      # Explicit host string takes precedence
      explicit_host && is_binary(explicit_host) ->
        Logger.debug("Agent.connect: using explicit host #{explicit_host}")
        explicit_host

      # Explicit IP tuple or string
      explicit_ip ->
        formatted = format_ip(explicit_ip)
        Logger.debug("Agent.connect: using explicit IP #{formatted}")
        formatted

      # Fall back to container lookup
      true ->
        Logger.debug("Agent.connect: looking up container #{container_id}")
        case get_vm_ip(container_id) do
          {:ok, ip} -> ip
          {:error, reason} ->
            Logger.error("Agent.connect: container lookup failed: #{inspect(reason)}")
            throw({:error, reason})
        end
    end

    ip_charlist = String.to_charlist(ip_str)

    Logger.debug("Agent.connect: connecting to #{ip_str}:#{port}")

    case :gen_tcp.connect(ip_charlist, port, [:binary, active: false, packet: :line], @connect_timeout) do
      {:ok, _} = result -> result
      {:error, reason} = error ->
        Logger.error("Agent.connect: TCP connect failed to #{ip_str}:#{port}: #{inspect(reason)}")
        error
    end
  end

  defp do_call(socket, method, params, timeout) do
    request_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    request = %{
      id: request_id,
      method: method,
      params: params
    }

    json = Jason.encode!(request) <> "\n"

    with :ok <- :gen_tcp.send(socket, json),
         {:ok, line} <- :gen_tcp.recv(socket, 0, timeout) do
      case Jason.decode(line) do
        {:ok, %{"id" => ^request_id} = response} ->
          {:ok, response}
        {:ok, response} ->
          {:error, {:id_mismatch, response}}
        {:error, reason} ->
          {:error, {:json_decode, reason}}
      end
    end
  end

  defp get_vm_ip(container_id) do
    case Zypi.Store.Containers.get(container_id) do
      {:ok, %{ip: {a, b, c, d}}} -> {:ok, "#{a}.#{b}.#{c}.#{d}"}
      {:ok, %{ip: ip}} when is_binary(ip) -> {:ok, ip}
      {:ok, %{ip: nil}} -> {:error, :no_ip}
      {:error, _} = error -> error
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip) when is_binary(ip), do: ip
end
