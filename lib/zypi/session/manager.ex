defmodule Zypi.Session.Manager do
  @moduledoc """
  Server-side session manager for long-lived agent sandboxes.

  Sessions keep a Firecracker VM alive across multiple exec calls,
  essential for multi-step agent workflows (install deps → run script →
  check output → iterate).

  Sessions auto-expire after an idle timeout to prevent resource leaks.

  ## Integration

  Called by the HTTP API router. MosaicDB's fabric tools use these
  endpoints for `fabric_sandbox_session` (create/exec/close).
  """

  use GenServer
  require Logger

  alias Zypi.Pool.VMPool
  alias Zypi.Container.Agent

  @default_idle_timeout_ms 300_000
  @cleanup_interval_ms 60_000

  defmodule State do
    defstruct sessions: %{}, idle_timeout_ms: 300_000
  end

  defmodule Session do
    defstruct [
      :id,
      :container_id,
      :ip,
      :image,
      :status,
      :agent_id,
      :created_at,
      :last_used_at,
      :metadata
    ]
  end

  # ── Public API ────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Create a new session (creates container + starts VM)."
  def create(agent_id \\ nil, image \\ "ubuntu:24.04", opts \\ []) do
    GenServer.call(__MODULE__, {:create, agent_id, image, opts}, 30_000)
  end

  @doc "Execute a command in an existing session."
  def exec(session_id, cmd, opts \\ []) do
    GenServer.call(__MODULE__, {:exec, session_id, cmd, opts}, 60_000)
  end

  @doc "Get session info."
  def get(session_id) do
    GenServer.call(__MODULE__, {:get, session_id})
  end

  @doc "List all active sessions."
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Close a session (stop VM + release resources)."
  def close(session_id) do
    GenServer.call(__MODULE__, {:close, session_id}, 15_000)
  end

  @doc "Close all sessions for an agent."
  def close_agent_sessions(agent_id) do
    GenServer.call(__MODULE__, {:close_agent, agent_id}, 30_000)
  end

  @doc "Get session stats."
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ── GenServer Callbacks ───────────────────────────────────────

  @impl true
  def init(opts) do
    idle_timeout = Keyword.get(opts, :idle_timeout_ms, @default_idle_timeout_ms)
    state = %State{idle_timeout_ms: idle_timeout}
    Process.send_after(self(), :cleanup_idle, @cleanup_interval_ms)
    Process.send_after(self(), :health_check_sessions, 30_000)
    Logger.info("Session.Manager started (idle_timeout=#{div(idle_timeout, 1000)}s)")
    {:ok, state}
  end

  @impl true
  def handle_call({:create, agent_id, image, opts}, _from, state) do
    session_id = generate_session_id()
    container_id = "sess_" <> random_id()

    result =
      with {:ok, container} <- Zypi.Container.Manager.create(%{
             id: container_id, image: image,
             resources: %{cpu: Keyword.get(opts, :vcpus, 1), memory_mb: Keyword.get(opts, :memory_mb, 256)}
           }),
           {:ok, _} <- Zypi.Container.Manager.start(container_id),
           :ok <- Agent.wait_ready(container_id, 30_000) do
        session = %Session{
          id: session_id,
          container_id: container_id,
          ip: container.ip,
          image: image,
          status: :running,
          agent_id: agent_id,
          created_at: DateTime.utc_now(),
          last_used_at: DateTime.utc_now(),
          metadata: Keyword.get(opts, :metadata, %{})
        }

        Logger.info("Session #{session_id} created (container=#{container_id}, agent=#{agent_id}, image=#{image})")

        {:ok, session}
      else
        {:error, reason} ->
          Logger.error("Session create failed: #{inspect(reason)}")
          # Best-effort cleanup
          Zypi.Container.Manager.destroy(container_id)
          {:error, reason}
      end

    case result do
      {:ok, session} ->
        state = %{state | sessions: Map.put(state.sessions, session_id, session)}
        {:reply, {:ok, session}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:exec, session_id, cmd, opts}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :session_not_found}, state}

      %{status: :closed} = session ->
        {:reply, {:error, {:session_closed, session_id}}, state}

      session ->
        exec_opts =
          [
            env: Keyword.get(opts, :env, %{}),
            workdir: Keyword.get(opts, :workdir),
            stdin: Keyword.get(opts, :stdin),
            timeout: Keyword.get(opts, :timeout, 60),
            ip: session.ip
          ]
          |> Enum.reject(fn {_, v} -> is_nil(v) end)

        result = Agent.exec(session.container_id, cmd, exec_opts)

        # Bump last_used_at regardless of exec result
        session = %{session | last_used_at: DateTime.utc_now()}
        state = %{state | sessions: Map.put(state.sessions, session_id, session)}

        case result do
          {:ok, exec_result} ->
            {:reply,
             {:ok,
              %{
                exit_code: exec_result.exit_code,
                stdout: exec_result.stdout,
                stderr: exec_result.stderr,
                timed_out: exec_result.timed_out,
                signal: exec_result.signal,
                session_id: session_id,
                container_id: session.container_id
              }}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:get, session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil -> {:reply, {:error, :not_found}, state}
      session -> {:reply, {:ok, session}, state}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    sessions =
      state.sessions
      |> Map.values()
      |> Enum.map(&session_json/1)
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

    {:reply, {:ok, sessions}, state}
  end

  @impl true
  def handle_call({:close, session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      session ->
        do_close(session)
        state = %{state | sessions: Map.delete(state.sessions, session_id)}
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:close_agent, agent_id}, _from, state) do
    {to_close, remaining} =
      state.sessions
      |> Enum.split_with(fn {_id, s} -> s.agent_id == agent_id end)

    Enum.each(to_close, fn {_id, session} -> do_close(session) end)

    state = %{state | sessions: Map.new(remaining)}
    {:reply, {:ok, length(to_close)}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    sessions = Map.values(state.sessions)
    stats = %{
      total: length(sessions),
      running: Enum.count(sessions, &(&1.status == :running)),
      by_image: Enum.frequencies_by(sessions, & &1.image),
      by_agent: sessions |> Enum.map(& &1.agent_id) |> Enum.reject(&is_nil/1) |> Enum.frequencies()
    }
    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup_idle, state) do
    now = DateTime.utc_now()
    threshold = DateTime.add(now, -div(state.idle_timeout_ms, 1000), :second)

    {expired, active} =
      state.sessions
      |> Enum.split_with(fn {_id, s} ->
        s.status == :running and not is_nil(s.last_used_at) and
          DateTime.compare(s.last_used_at, threshold) == :lt
      end)

    if length(expired) > 0 do
      Logger.info("Session.Manager: cleaning up #{length(expired)} idle sessions")
      Enum.each(expired, fn {id, session} ->
        Logger.debug("Session #{id} expired (last used: #{session.last_used_at})")
        do_close(session)
      end)
    end

    state = %{state | sessions: Map.new(active)}
    Process.send_after(self(), :cleanup_idle, @cleanup_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:health_check_sessions, state) do
    running = state.sessions
      |> Enum.filter(fn {_id, s} -> s.status == :running end)

    {healthy, unhealthy} =
      running
      |> Enum.split_with(fn {_id, s} ->
        case Agent.health(s.container_id) do
          {:ok, %{"status" => "healthy"}} -> true
          _ -> false
        end
      end)

    if length(unhealthy) > 0 do
      Logger.warning("Session.Manager: #{length(unhealthy)} unhealthy sessions detected")

      sessions = Enum.reduce(unhealthy, state.sessions, fn {id, session}, acc ->
        Logger.info("Session #{id} marked unhealthy (container=#{session.container_id})")
        do_close(session)
        Map.delete(acc, id)
      end)

      state = %{state | sessions: sessions}
    end

    Process.send_after(self(), :health_check_sessions, 30_000)
    {:noreply, state}
  end

  # ── Private ───────────────────────────────────────────────────

  defp do_close(session) do
    Logger.info("Session #{session.id} closing (container=#{session.container_id})")
    VMPool.release(session.container_id)
    Zypi.Container.Manager.destroy(session.container_id)
  rescue
    e ->
      Logger.warning("Session cleanup error for #{session.id}: #{inspect(e)}")
      :ok
  end

  defp generate_session_id do
    "fabric_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp random_id do
    :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
  end

  defp session_json(%Session{} = s) do
    %{
      id: s.id,
      container_id: s.container_id,
      ip: format_ip(s.ip),
      image: s.image,
      status: s.status,
      agent_id: s.agent_id,
      created_at: s.created_at && DateTime.to_iso8601(s.created_at),
      last_used_at: s.last_used_at && DateTime.to_iso8601(s.last_used_at),
      idle_seconds: idle_seconds(s)
    }
  end

  defp idle_seconds(%{last_used_at: nil}), do: nil

  defp idle_seconds(%{last_used_at: last_used}) do
    DateTime.diff(DateTime.utc_now(), last_used)
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(nil), do: nil
end
