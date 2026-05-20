defmodule Zypi.API.GrpcServer do
  @moduledoc """
  gRPC server for Zypi sandbox execution on port 4001.

  Accepts protobuf-encoded requests over HTTP/2, routes to existing
  Executor/SessionManager logic, returns protobuf-encoded responses.

  Wire format: 1-byte compression flag (0) + 4-byte big-endian length + protobuf.

  REST API remains on port 4000 for backward compatibility.
  """

  use Plug.Router
  require Logger

  alias Zypi.Executor
  alias Zypi.Session.Manager, as: SessionManager
  alias Zypi.Pool.VMPool
  alias Zypi.Pool.ImageStore
  alias Zypi.Store.Images, as: StoreImages

  plug Plug.Logger, log: :debug
  plug :match
  plug :dispatch

  # ── gRPC Dispatch ───────────────────────────────────────────

  post "/zypi.v1.ZypiService/Execute" do
    raw = read_grpc_body(conn)
    req = Zypi.V1.SandboxExecRequest.decode(raw)

    cmd = req.command
    opts = build_exec_opts(req)

    case Executor.run(cmd, opts) do
      {:ok, result} ->
        resp = %Zypi.V1.SandboxExecResponse{
          stdout: result.stdout || "",
          stderr: result.stderr || "",
          exit_code: result.exit_code,
          duration_ms: result.duration_ms,
          sandbox_id: result.container_id || "",
          timed_out: Map.get(result, :timed_out, false)
        }
        send_grpc(conn, resp)

      {:error, reason} ->
        send_grpc_error(conn, 2, inspect(reason))
    end
  end

  post "/zypi.v1.ZypiService/CreateSession" do
    raw = read_grpc_body(conn)
    req = Zypi.V1.CreateSessionRequest.decode(raw)

    opts = [
      vcpus: if(req.vcpus && req.vcpus > 0, do: req.vcpus, else: 1),
      memory_mb: if(req.memory_mb && req.memory_mb > 0, do: req.memory_mb, else: 256)
    ]

    case SessionManager.create(req.agent_id, empty_to_nil(req.image) || "ubuntu:24.04", opts) do
      {:ok, session} ->
        resp = %Zypi.V1.SessionResponse{
          session_id: session.id,
          container_id: session.container_id || "",
          ip: format_ip(session.ip),
          image: session.image || "",
          agent_id: session.agent_id || "",
          status: "running",
          created_at: DateTime.to_iso8601(session.created_at)
        }
        send_grpc(conn, resp)

      {:error, reason} ->
        send_grpc_error(conn, 13, inspect(reason))
    end
  end

  post "/zypi.v1.ZypiService/SessionExec" do
    raw = read_grpc_body(conn)
    req = Zypi.V1.SessionExecRequest.decode(raw)

    opts = [
      timeout: if(req.timeout_secs && req.timeout_secs > 0, do: req.timeout_secs, else: 30),
      env: req.env || %{},
      workdir: empty_to_nil(req.workdir)
    ] |> Enum.reject(fn {_, v} -> is_nil(v) end)

    case SessionManager.exec(req.session_id, req.command, opts) do
      {:ok, result} ->
        resp = %Zypi.V1.SandboxExecResponse{
          stdout: result.stdout || "",
          stderr: result.stderr || "",
          exit_code: result.exit_code,
          duration_ms: Map.get(result, :duration_ms, 0),
          sandbox_id: result.container_id || req.session_id,
          timed_out: Map.get(result, :timed_out, false)
        }
        send_grpc(conn, resp)

      {:error, reason} ->
        status = case reason do
          :session_not_found -> 5   # NOT_FOUND
          {:session_closed, _} -> 9 # FAILED_PRECONDITION
          _ -> 2                    # UNKNOWN
        end
        send_grpc_error(conn, status, inspect(reason))
    end
  end

  post "/zypi.v1.ZypiService/GetSession" do
    raw = read_grpc_body(conn)
    req = Zypi.V1.GetSessionRequest.decode(raw)

    case SessionManager.get(req.session_id) do
      {:ok, session} ->
        resp = %Zypi.V1.SessionResponse{
          session_id: session.id,
          container_id: session.container_id || "",
          ip: format_ip(session.ip),
          image: session.image || "",
          agent_id: session.agent_id || "",
          status: session.status || "unknown",
          created_at: session.created_at && DateTime.to_iso8601(session.created_at) || ""
        }
        send_grpc(conn, resp)

      {:error, :not_found} ->
        send_grpc_error(conn, 5, "session not found")
    end
  end

  post "/zypi.v1.ZypiService/ListSessions" do
    raw = read_grpc_body(conn)
    _req = Zypi.V1.ListSessionsRequest.decode(raw)

    {:ok, sessions} = SessionManager.list()
    session_list = Enum.map(sessions, fn s ->
      %Zypi.V1.SessionResponse{
        session_id: s.id,
        container_id: s.container_id || "",
        ip: format_ip(s.ip),
        image: s.image || "",
        agent_id: s.agent_id || "",
        status: s.status || "unknown",
        created_at: s.created_at && DateTime.to_iso8601(s.created_at) || ""
      }
    end)

    resp = %Zypi.V1.ListSessionsResponse{
      sessions: session_list,
      count: length(session_list)
    }
    send_grpc(conn, resp)
  end

  post "/zypi.v1.ZypiService/CloseSession" do
    raw = read_grpc_body(conn)
    req = Zypi.V1.CloseSessionRequest.decode(raw)

    case SessionManager.close(req.session_id) do
      :ok ->
        resp = %Zypi.V1.CloseSessionResponse{status: "closed"}
        send_grpc(conn, resp)

      {:error, :not_found} ->
        send_grpc_error(conn, 5, "session not found")
    end
  end

  post "/zypi.v1.ZypiService/SessionStats" do
    raw = read_grpc_body(conn)
    _req = Zypi.V1.SessionStatsRequest.decode(raw)

    stats = SessionManager.stats()
    resp = %Zypi.V1.SessionStatsResponse{
      total: Map.get(stats, :total, 0),
      running: Map.get(stats, :running, 0),
      closed: Map.get(stats, :closed, 0),
      expired: Map.get(stats, :expired, 0)
    }
    send_grpc(conn, resp)
  end

  post "/zypi.v1.ZypiService/ListImages" do
    raw = read_grpc_body(conn)
    _req = Zypi.V1.ListImagesRequest.decode(raw)

    images = ImageStore.list_images()
    |> Enum.map(fn img ->
      %Zypi.V1.ImageInfo{
        ref: img.ref || "",
        status: to_string(img.status || "unknown"),
        progress: img.progress || 0,
        current_step: img.current_step || "",
        total_layers: img.total_layers || 0,
        applied_layers: img.applied_layers || 0,
        size_bytes: img.size_bytes || 0,
        error_message: img.error_message || "",
        started_at: img.started_at && DateTime.to_iso8601(img.started_at) || "",
        completed_at: img.completed_at && DateTime.to_iso8601(img.completed_at) || ""
      }
    end)

    resp = %Zypi.V1.ListImagesResponse{images: images}
    send_grpc(conn, resp)
  end

  post "/zypi.v1.ZypiService/ImageStatus" do
    raw = read_grpc_body(conn)
    req = Zypi.V1.ImageStatusRequest.decode(raw)

    case StoreImages.get(req.ref) do
      {:ok, img} ->
        info = %Zypi.V1.ImageInfo{
          ref: img.ref || "",
          status: to_string(img.status || "unknown"),
          progress: img.progress || 0,
          current_step: img.current_step || "",
          total_layers: img.total_layers || 0,
          applied_layers: img.applied_layers || 0,
          size_bytes: img.size_bytes || 0,
          error_message: img.error_message || "",
          started_at: img.started_at && DateTime.to_iso8601(img.started_at) || "",
          completed_at: img.completed_at && DateTime.to_iso8601(img.completed_at) || ""
        }
        resp = %Zypi.V1.ImageStatusResponse{image: info}
        send_grpc(conn, resp)

      {:error, :not_found} ->
        send_grpc_error(conn, 5, "image not found")
    end
  end

  post "/zypi.v1.ZypiService/WarmImage" do
    raw = read_grpc_body(conn)
    req = Zypi.V1.WarmImageRequest.decode(raw)

    count = min(req.count, 10)
    VMPool.warm_for_image(req.ref, count)

    resp = %Zypi.V1.WarmImageResponse{
      status: "warming",
      image: req.ref,
      requested: count,
      message: "VMs will boot in background. Check PoolStatus for warm VM count."
    }
    send_grpc(conn, resp)
  end

  post "/zypi.v1.ZypiService/WarmStatus" do
    raw = read_grpc_body(conn)
    req = Zypi.V1.WarmStatusRequest.decode(raw)

    stats = VMPool.stats()
    by_image = get_in(stats, [:by_image]) || %{}
    warm_count = Map.get(by_image, req.ref, 0)

    resp = %Zypi.V1.WarmStatusResponse{
      image: req.ref,
      warm_vms: warm_count
    }
    send_grpc(conn, resp)
  end

  post "/zypi.v1.ZypiService/PoolStatus" do
    raw = read_grpc_body(conn)
    _req = Zypi.V1.PoolStatusRequest.decode(raw)

    stats = VMPool.stats()
    by_image = get_in(stats, [:by_image]) || %{}
    by_image_strings = Map.new(by_image, fn {k, v} -> {to_string(k), v} end)

    resp = %Zypi.V1.PoolStatusResponse{
      total_vms: Map.get(stats, :total_vms, 0),
      warm_vms: Map.get(stats, :warm_vms, 0),
      active_vms: Map.get(stats, :active_vms, 0),
      by_image: by_image_strings
    }
    send_grpc(conn, resp)
  end

  post "/zypi.v1.ZypiService/Health" do
    raw = read_grpc_body(conn)
    _req = Zypi.V1.HealthRequest.decode(raw)

    resp = %Zypi.V1.HealthResponse{
      status: "ok",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
    send_grpc(conn, resp)
  end

  # Catch-all for unimplemented RPCs
  match _ do
    send_grpc_error(conn, 12, "unimplemented RPC")
  end

  # ── gRPC Wire Helpers ───────────────────────────────────────

  defp read_grpc_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn, length: 10_000_000)
    # Strip 5-byte gRPC framing: 1 byte compression flag + 4 bytes length
    case body do
      <<_compressed::8, _len::32-big, msg::binary>> -> msg
      _ -> body
    end
  end

  defp send_grpc(conn, message) do
    try do
      encoded = message.__struct__.encode(message)
      len = byte_size(encoded)
      framed = <<0, len::32-big, encoded::binary>>

      conn
      |> put_resp_header("grpc-status", "0")
      |> put_resp_header("grpc-message", "OK")
      |> put_resp_content_type("application/grpc+proto")
      |> send_resp(200, framed)
    rescue
      e ->
        Logger.error("gRPC encode error: #{inspect(e)}")
        send_grpc_error(conn, 13, "internal encode error")
    end
  end

  defp send_grpc_error(conn, grpc_status, message) do
    conn
    |> put_resp_header("grpc-status", to_string(grpc_status))
    |> put_resp_header("grpc-message", message)
    |> put_resp_content_type("application/grpc+proto")
    |> send_resp(200, <<0, 0, 0, 0, 0>>)
  end

  # ── Helpers ─────────────────────────────────────────────────

  defp build_exec_opts(req) do
    [
      image: empty_to_nil(req.image),
      timeout: if(req.timeout_secs > 0, do: req.timeout_secs),
      memory_mb: if(req.memory_mb && req.memory_mb > 0, do: req.memory_mb),
      vcpus: if(req.vcpus && req.vcpus > 0, do: req.vcpus),
      env: if(req.env && map_size(req.env) > 0, do: req.env),
      workdir: empty_to_nil(req.workdir),
      files: if(req.files && map_size(req.files) > 0, do: req.files)
    ] |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(str) when is_binary(str), do: str
  defp empty_to_nil(other), do: other

  defp format_ip(nil), do: ""
  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

end
