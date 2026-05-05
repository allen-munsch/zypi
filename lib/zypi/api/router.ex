defmodule Zypi.API.Router do
  use Plug.Router
  require Logger

  alias Zypi.Container.Manager
  alias Zypi.Store.Containers
  alias Zypi.Pool.ImageStore
  alias Zypi.API.ConsoleSocket
  alias Zypi.Store.Images, as: StoreImages
  alias Zypi.Image.Importer, as: ImageImporter
  alias Zypi.Executor
  alias Zypi.Session.Manager, as: SessionManager
  alias Zypi.Pool.VMPool

  defmodule Zypi.API.RequestTimer do
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, _opts) do
      start_time = System.monotonic_time()

      Plug.Conn.register_before_send(conn, fn conn ->
        duration = System.monotonic_time() - start_time
        duration_ms = System.convert_time_unit(duration, :native, :millisecond)

        :telemetry.execute(
          [:zypi, :api, :request],
          %{duration_ms: duration_ms},
          %{
            path: conn.request_path,
            method: conn.method,
            status: conn.status
          }
        )

        # Add timing header
        Plug.Conn.put_resp_header(conn, "x-request-time-ms", to_string(duration_ms))
      end)
    end
  end

  plug Plug.Logger
  plug Zypi.API.RequestTimer  # Add this line
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["application/json", "application/octet-stream", "application/x-tar", "application/gzip", "application/x-gzip"]
  plug :dispatch

  get "/health" do
    send_json(conn, 200, %{status: "ok", timestamp: DateTime.utc_now()})
  end

  get "/status" do
  status = %{
    containers: Containers.count_by_status(),
    images: length(ImageStore.list_images())
  }
  send_json(conn, 200, status)
end

  get "/images" do
  send_json(conn, 200, %{images: ImageStore.list_images()})
end

get "/images/:ref/status" do
  case StoreImages.get(ref) do
    {:ok, image} ->
      response = %{
        ref: image.ref,
        status: image.status,
        progress: image.progress || 0,
        current_step: image.current_step,
        total_layers: image.total_layers || 0,
        applied_layers: image.applied_layers || 0,
        size_bytes: image.size_bytes,
        error_message: image.error_message,
        started_at: image.started_at && DateTime.to_iso8601(image.started_at),
        completed_at: image.completed_at && DateTime.to_iso8601(image.completed_at)
      }
      send_json(conn, 200, response)
    {:error, :not_found} ->
      send_json(conn, 404, %{error: "not_found"})
  end
end

get "/images/importing" do
  active_imports = StoreImages.list()
  |> Enum.filter(fn image ->
    image.status in [:queued, :importing, :extracting, :applying_layers, :injecting_init]
  end)
  |> Enum.map(fn image ->
    %{
      ref: image.ref,
      status: image.status,
      progress: image.progress || 0,
      current_step: image.current_step,
      applied_layers: image.applied_layers || 0,
      total_layers: image.total_layers || 0,
      started_at: image.pulled_at && DateTime.to_iso8601(image.pulled_at)
    }
  end)

  send_json(conn, 200, %{imports: active_imports, count: length(active_imports)})
end

    post "/images/:ref/import" do
  content_type = List.first(Plug.Conn.get_req_header(conn, "content-type") || [])
  is_binary = content_type && (String.starts_with?(content_type, "application/octet-stream") || content_type == "application/x-tar" || String.contains?(content_type, "tar"))

  if is_binary do
    temp_path = Path.join(System.tmp_dir!(), "import-#{:crypto.strong_rand_bytes(8) |> Base.encode16()}.tar")

    try do
      case stream_body_to_file(conn, temp_path) do
        {:ok, conn, bytes_read} ->
          Logger.info("Streamed #{bytes_read} bytes for #{ref}")
          tar_data = File.read!(temp_path)

          case ImageImporter.import_tar(ref, tar_data) do
            {:ok, :accepted, ref} ->
              send_json(conn, 202, %{status: "accepted", ref: ref})
            {:error, reason} ->
              send_json(conn, 500, %{error: inspect(reason)})
          end

        {:error, :body_too_large} ->
          send_json(conn, 413, %{error: "Payload too large"})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    after
      File.rm(temp_path)
    end
  else
    send_json(conn, 415, %{error: "Unsupported Media Type"})
  end
end


  delete "/images/:ref" do
  case ImageStore.delete_image(ref) do
    :ok -> send_json(conn, 200, %{status: "deleted"})
    {:error, :not_found} -> send_json(conn, 404, %{error: "not_found"})
  end
end

  get "/containers" do
    send_json(conn, 200, %{containers: Manager.list() |> Enum.map(&container_json/1)})
  end

  get "/containers/:id" do
    case Containers.get(id) do
      {:ok, c} -> send_json(conn, 200, container_json(c))
      {:error, :not_found} -> send_json(conn, 404, %{error: "not_found"})
    end
  end

  get "/containers/:id/console_port" do
    if Containers.get(id) do
      send_json(conn, 200, %{port: ConsoleSocket.get_port()})
    else
      send_json(conn, 404, %{error: "not_found"})
    end
  end

  get "/containers/:id/shell_info" do
    case Manager.get_shell_info(id) do
      {:ok, info} ->
        send_json(conn, 200, info)

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "not_found"})

      {:error, {:not_running, status}} ->
        send_json(conn, 400, %{
          error: "container_not_running",
          status: to_string(status),
          message: "Container must be running to access shell"
        })

      {:error, :ssh_not_configured} ->
        send_json(conn, 500, %{
          error: "ssh_not_configured",
          message: "SSH key not found. Shell access unavailable."
        })
    end
  end

  get "/containers/:id/ssh_ready" do
    ready = Manager.ssh_ready?(id)
    send_json(conn, 200, %{ready: ready})
  end

  post "/containers" do
    Logger.info("API: POST /containers - #{inspect(conn.body_params)}")
    params = %{
      id: conn.body_params["id"],
      image: conn.body_params["image"],
      resources: conn.body_params["resources"],
      metadata: %{cmd: parse_cmd(conn.body_params["cmd"])}
    } |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()

    case Manager.create(params) do
      {:ok, c} -> send_json(conn, 201, container_json(c))
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/containers/:id/start" do
    case Manager.start(id) do
      {:ok, _} -> send_json(conn, 200, %{status: "started"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/containers/:id/stop" do
    case Manager.stop(id) do
      {:ok, _} -> send_json(conn, 200, %{status: "stopped"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  delete "/containers/:id" do
    case Manager.destroy(id) do
      {:ok, _} -> send_json(conn, 200, %{status: "destroyed"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/containers/:id/logs" do
    case Manager.get_output(id) do
      {:ok, output} -> send_json(conn, 200, %{logs: output})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/containers/:id/attach" do
    case Containers.get(id) do
      {:ok, %{status: status}} when status in [:running, :exited] ->
        conn = conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("connection", "keep-alive")
        |> send_chunked(200)
        Manager.subscribe(id)
        {:ok, output} = Manager.get_output(id)
        if output != "", do: chunk(conn, "data: #{Base.encode64(output)}\n\n")
        stream_output(conn, id)
      {:ok, _} -> send_json(conn, 400, %{error: "container_not_running"})
      {:error, :not_found} -> send_json(conn, 404, %{error: "not_found"})
    end
  end


  get "/debug/vmpool" do
    stats = VMPool.stats()
    vm_ids = try do
      Zypi.Pool.VMPool.active_vm_ids()
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end

    send_json(conn, 200, %{
      stats: stats,
      vm_ids: vm_ids,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  get "/debug/containers" do
    containers = Zypi.Store.Containers.list()
    |> Enum.map(fn c ->
      %{
        id: c.id,
        status: c.status,
        ip: format_ip(c.ip),
        image: c.image,
        created_at: c.created_at && DateTime.to_iso8601(c.created_at)
      }
    end)

    send_json(conn, 200, %{
      containers: containers,
      count: length(containers),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  get "/debug/images" do
    images = Zypi.Store.Images.list()
    |> Enum.map(fn img ->
      %{
        ref: img.ref,
        status: img.status,
        progress: img.progress,
        size_bytes: img.size_bytes,
        device: img.device
      }
    end)

    send_json(conn, 200, %{
      images: images,
      count: length(images),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  get "/debug/cleanup" do
    stats = Zypi.System.Cleanup.stats()
    send_json(conn, 200, stats)
  end

  post "/debug/cleanup/run" do
    case Zypi.System.Cleanup.run_cleanup() do
      {:ok, stats} -> send_json(conn, 200, %{status: "ok", stats: stats})
      error -> send_json(conn, 500, %{error: inspect(error)})
    end
  end

  # Test agent connectivity directly
  get "/debug/agent/:container_id" do
    # Try to get container from store
    container_result = Zypi.Store.Containers.get(container_id)

    # Try to find in VMPool
    vm_pool_ids = try do
      Zypi.Pool.VMPool.active_vm_ids()
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end

    in_pool = container_id in vm_pool_ids

    result = %{
      container_id: container_id,
      in_store: match?({:ok, _}, container_result),
      in_pool: in_pool,
      store_data: case container_result do
        {:ok, c} -> %{id: c.id, ip: format_ip(c.ip), status: c.status}
        _ -> nil
      end
    }

    send_json(conn, 200, result)
  end

  # Test direct agent call with explicit IP
  post "/debug/agent/call" do
    ip = conn.body_params["ip"]
    method = conn.body_params["method"] || "health"
    params = conn.body_params["params"] || %{}

    if is_nil(ip) do
      send_json(conn, 400, %{error: "ip required"})
    else
      result = try do
        Zypi.Container.Agent.call("debug", method, params, ip: ip)
      rescue
        e -> {:error, Exception.message(e)}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

      case result do
        {:ok, data} -> send_json(conn, 200, %{status: "ok", result: data})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end
  end


  defp stream_body_to_file(conn, file_path, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, 1_048_576)  # 1MB chunks
    max_size = Keyword.get(opts, :max_size, 500_000_000)    # 500MB max

    File.open!(file_path, [:write, :binary], fn file ->
      stream_chunks(conn, file, 0, chunk_size, max_size)
    end)
  end

  defp stream_chunks(conn, file, total_read, chunk_size, max_size) when total_read < max_size do
    case Plug.Conn.read_body(conn, length: chunk_size, read_length: chunk_size) do
      {:ok, data, conn} ->
        IO.binwrite(file, data)
        {:ok, conn, total_read + byte_size(data)}

      {:more, data, conn} ->
        IO.binwrite(file, data)
        new_total = total_read + byte_size(data)
        if new_total >= max_size do
          {:error, :body_too_large}
        else
          stream_chunks(conn, file, new_total, chunk_size, max_size)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_chunks(_conn, _file, total_read, _chunk_size, max_size) when total_read >= max_size do
    {:error, :body_too_large}
  end

  # ── Agent Fabric: One-Shot Sandbox Execution ──────────────────

  post "/exec" do
    cmd = conn.body_params["cmd"]

    if is_nil(cmd) or not is_list(cmd) do
      send_json(conn, 400, %{error: "cmd must be a list of strings"})
    else
      agent_id = conn.body_params["agent_id"]
      stream? = conn.body_params["stream"] == true

      opts = [
        image: conn.body_params["image"],
        env: conn.body_params["env"],
        workdir: conn.body_params["workdir"],
        timeout: conn.body_params["timeout"],
        files: conn.body_params["files"],
        memory_mb: conn.body_params["memory_mb"],
        vcpus: conn.body_params["vcpus"]
      ] |> Enum.reject(fn {_, v} -> is_nil(v) end)

      if stream? do
        stream_exec(conn, cmd, opts, agent_id)
      else
        case Executor.run(cmd, opts) do
          {:ok, result} ->
            response = %{
              exit_code: result.exit_code,
              stdout: result.stdout,
              stderr: result.stderr,
              duration_ms: result.duration_ms,
              container_id: result.container_id
            }
            response = if agent_id, do: Map.put(response, :agent_id, agent_id), else: response
            send_json(conn, 200, response)
          {:error, reason} ->
            send_json(conn, 500, %{error: inspect(reason)})
        end
      end
    end
  end

  # ── Agent Fabric: Long-Lived Sessions ────────────────────────

  post "/sessions" do
    agent_id = conn.body_params["agent_id"]
    image = conn.body_params["image"] || "ubuntu:24.04"

    opts = [
      vcpus: conn.body_params["vcpus"] || 1,
      memory_mb: conn.body_params["memory_mb"] || 256,
      metadata: conn.body_params["metadata"] || %{}
    ]

    case SessionManager.create(agent_id, image, opts) do
      {:ok, session} ->
        send_json(conn, 201, %{
          session_id: session.id,
          container_id: session.container_id,
          ip: format_ip(session.ip),
          image: session.image,
          agent_id: session.agent_id,
          status: "running",
          created_at: DateTime.to_iso8601(session.created_at)
        })
      {:error, reason} ->
        send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/sessions/:id/exec" do
    cmd = conn.body_params["cmd"]

    if is_nil(cmd) or not is_list(cmd) do
      send_json(conn, 400, %{error: "cmd must be a list of strings"})
    else
      stream? = conn.body_params["stream"] == true
      opts = [
        env: conn.body_params["env"],
        workdir: conn.body_params["workdir"],
        timeout: conn.body_params["timeout"] || 30
      ] |> Enum.reject(fn {_, v} -> is_nil(v) end)

      if stream? do
        stream_session_exec(conn, id, cmd, opts)
      else
        case SessionManager.exec(id, cmd, opts) do
          {:ok, result} ->
            send_json(conn, 200, %{
              exit_code: result.exit_code,
              stdout: result.stdout,
              stderr: result.stderr,
              timed_out: result.timed_out || false,
              session_id: result.session_id,
              container_id: result.container_id
            })
          {:error, reason} ->
            status = case reason do
              :session_not_found -> 404
              {:session_closed, _} -> 410
              _ -> 500
            end
            send_json(conn, status, %{error: inspect(reason)})
        end
      end
    end
  end

  get "/sessions/:id" do
    case SessionManager.get(id) do
      {:ok, session} ->
        send_json(conn, 200, %{
          session_id: session.id,
          container_id: session.container_id,
          ip: format_ip(session.ip),
          image: session.image,
          agent_id: session.agent_id,
          status: session.status,
          created_at: DateTime.to_iso8601(session.created_at),
          last_used_at: session.last_used_at && DateTime.to_iso8601(session.last_used_at)
        })
      {:error, :not_found} ->
        send_json(conn, 404, %{error: "session not found"})
    end
  end

  get "/sessions" do
    {:ok, sessions} = SessionManager.list()
    send_json(conn, 200, %{sessions: sessions, count: length(sessions)})
  end

  delete "/sessions/:id" do
    case SessionManager.close(id) do
      :ok -> send_json(conn, 200, %{status: "closed"})
      {:error, :not_found} -> send_json(conn, 404, %{error: "session not found"})
    end
  end

  get "/sessions/stats" do
    stats = SessionManager.stats()
    send_json(conn, 200, stats)
  end

  # ── Image Pre-Warming (Agent Fabric optimization) ────────────

  post "/images/:ref/warm" do
    count = (conn.body_params["count"] || 1)
    count = min(count, 10)  # Cap at 10

    VMPool.warm_for_image(ref, count)
    send_json(conn, 202, %{
      status: "warming",
      image: ref,
      requested: count,
      message: "VMs will boot in background. Check /pool/stats for warm VM count."
    })
  end

  get "/images/:ref/warm-status" do
    stats = VMPool.stats()
    pool_stats = get_in(stats, [:by_image]) || %{}
    warm_count = Map.get(pool_stats, ref, 0)

    send_json(conn, 200, %{
      image: ref,
      warm_vms: warm_count,
      pool_stats: stats
    })
  end

  # ── Pool ─────────────────────────────────────────────────────

  get "/pool/stats" do
    stats = VMPool.stats()
    send_json(conn, 200, stats)
  end

  match _ do
    send_json(conn, 404, %{error: "not_found"})
  end

  # ── SSE Streaming Helpers ───────────────────────────────────

  defp stream_exec(conn, cmd, opts, agent_id) do
    conn = conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    parent = self()
    caller = fn event, data ->
      send(parent, {:sse_chunk, event, data})
    end

    task = Task.async(fn ->
      Executor.run(cmd, opts)
    end)

    timeout_ms = (Keyword.get(opts, :timeout, 60) + 5) * 1000

    sse_loop(conn, task, agent_id, caller, timeout_ms)
  end

  defp stream_session_exec(conn, session_id, cmd, opts) do
    conn = conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    parent = self()
    caller = fn event, data ->
      send(parent, {:sse_chunk, event, data})
    end

    task = Task.async(fn ->
      SessionManager.exec(session_id, cmd, opts)
    end)

    timeout_ms = (Keyword.get(opts, :timeout, 30) + 5) * 1000

    sse_loop(conn, task, session_id, caller, timeout_ms)
  end

  defp sse_loop(conn, task, context_id, caller, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    last_keepalive = System.monotonic_time(:millisecond)

    do_sse_loop(conn, task, context_id, caller, deadline, last_keepalive)
  end

  defp do_sse_loop(conn, task, context_id, caller, deadline, last_keepalive) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= deadline ->
        Task.shutdown(task, :brutal_kill)
        event_chunk(conn, "error", Jason.encode!(%{error: "timeout", context_id: context_id}))

      # Send keepalive every 5 seconds
      now - last_keepalive >= 5_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} ->
            do_sse_loop(conn, task, context_id, caller, deadline, now)
          {:error, _} ->
            Task.shutdown(task, :brutal_kill)
            conn
        end

      true ->
        receive do
          {:sse_chunk, event, data} ->
            payload = if is_map(data) or is_list(data), do: Jason.encode!(data), else: to_string(data)

            case event_chunk(conn, event, payload) do
              {:ok, conn} ->
                do_sse_loop(conn, task, context_id, caller, deadline, now)
              {:error, _} ->
                Task.shutdown(task, :brutal_kill)
                conn
            end
        after
          100 ->
            # Check if task completed
            case Task.yield(task, 0) do
              nil ->
                do_sse_loop(conn, task, context_id, caller, deadline, now)

              {:ok, {:ok, result}} ->
                response = %{
                  exit_code: result[:exit_code] || result.exit_code,
                  stdout: result[:stdout] || "",
                  stderr: result[:stderr] || "",
                  duration_ms: result[:duration_ms],
                  container_id: result[:container_id] || result[:session_id],
                  context_id: context_id
                }
                {:ok, conn} = event_chunk(conn, "result", Jason.encode!(response))
                {:ok, conn} = event_chunk(conn, "done", "")
                conn

              {:ok, {:error, reason}} ->
                {:ok, conn} = event_chunk(conn, "error", Jason.encode!(%{error: inspect(reason), context_id: context_id}))
                conn

              {:exit, _reason} ->
                {:ok, conn} = event_chunk(conn, "error", Jason.encode!(%{error: "execution crashed", context_id: context_id}))
                conn
            end
        end
    end
  end

  defp event_chunk(conn, event, data) do
    chunk(conn, "event: #{event}\ndata: #{data}\n\n")
  end

  defp stream_output(conn, container_id) do
    receive do
      {:container_output, ^container_id, data} ->
        case chunk(conn, "data: #{Base.encode64(data)}\n\n") do
          {:ok, conn} -> stream_output(conn, container_id)
          {:error, _} -> Manager.unsubscribe(container_id)
        end
    after
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream_output(conn, container_id)
          {:error, _} -> Manager.unsubscribe(container_id)
        end
    end
  end

  defp send_json(conn, status, data) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(data))
  end

  defp container_json(c) do
    %{id: c.id, image: c.image, status: c.status, ip: format_ip(c.ip), rootfs: c.rootfs,
      created_at: c.created_at && DateTime.to_iso8601(c.created_at),
      started_at: c.started_at && DateTime.to_iso8601(c.started_at)}
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(nil), do: nil

  defp parse_cmd(nil), do: nil
  defp parse_cmd(cmd) when is_list(cmd), do: cmd
  defp parse_cmd(cmd) when is_binary(cmd), do: ["/bin/sh", "-c", cmd]
end
