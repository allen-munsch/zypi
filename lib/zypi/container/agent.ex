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

    case call(container_id, "exec", params) do
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

    case call(container_id, "file.write", params) do
      {:ok, %{"written" => bytes}} -> {:ok, bytes}
      error -> error
    end
  end

  @doc """
  Read a file from the VM.
  """
  def read_file(container_id, path) do
    case call(container_id, "file.read", %{path: path}) do
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
  def health(container_id) do
    call(container_id, "health", %{})
  end

  @doc """
  Request clean shutdown.
  """
  def shutdown(container_id) do
    call(container_id, "shutdown", %{})
  end

  @doc """
  Wait for the agent to become healthy.
  """
  def wait_ready(container_id, timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_ready(container_id, deadline)
  end

  defp do_wait_ready(container_id, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      case health(container_id) do
        {:ok, %{"status" => "healthy"}} ->
          :ok
        _ ->
          Process.sleep( @health_check_interval)
          do_wait_ready(container_id, deadline)
      end
    end
  end

  @doc """
  Make an RPC call to the agent.
  """
  def call(container_id, method, params, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @call_timeout)

    with {:ok, conn} <- connect(container_id),
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

  defp connect(container_id) do
    case get_vm_ip(container_id) do
      {:ok, ip} ->
        ip_charlist = ip |> to_charlist()
        :gen_tcp.connect(ip_charlist, @tcp_port, [
          :binary,
          active: false,
          packet: :line
        ], @connect_timeout)
      error -> error
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
end
