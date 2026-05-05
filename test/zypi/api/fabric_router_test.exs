defmodule Zypi.API.FabricRouterTest do
  use Plug.Test
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :fabric

  alias Zypi.API.Router
  alias Zypi.Session.Manager

  @opts Router.init([])

  setup do
    :ok
  end

  # ── POST /exec (with agent_id) ───────────────────────────────

  describe "POST /exec with agent_id" do
    test "executes command and returns result" do
      conn =
        conn(:post, "/exec", %{
          cmd: ["echo", "hello from test"],
          image: "ubuntu:24.04",
          agent_id: "test-agent-01"
        })
        |> put_req_header("content-type", "application/json")
        |> router_call()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["exit_code"] == 0
      assert body["stdout"] =~ "hello from test"
      assert body["agent_id"] == "test-agent-01"
      assert body["container_id"] =~ ~r/^exec_/
      assert is_integer(body["duration_ms"])
    end

    test "returns error for missing cmd" do
      conn =
        conn(:post, "/exec", %{image: "ubuntu:24.04"})
        |> put_req_header("content-type", "application/json")
        |> router_call()

      assert conn.status == 400
    end

    test "returns error for bad image" do
      conn =
        conn(:post, "/exec", %{cmd: ["echo", "hi"], image: "nonexistent:99"})
        |> put_req_header("content-type", "application/json")
        |> router_call()

      assert conn.status == 500
    end
  end

  # ── POST /sessions (create) ──────────────────────────────────

  describe "POST /sessions" do
    test "creates a session with agent_id" do
      conn =
        conn(:post, "/sessions", %{
          agent_id: "fabric-agent-01",
          image: "ubuntu:24.04"
        })
        |> put_req_header("content-type", "application/json")
        |> router_call()

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["session_id"] =~ ~r/^fabric_/
      assert body["agent_id"] == "fabric-agent-01"
      assert body["status"] == "running"
      assert body["ip"] != nil

      # Clean up
      Manager.close(body["session_id"])
    end

    test "defaults image when not specified" do
      conn =
        conn(:post, "/sessions", %{agent_id: "test-agent"})
        |> put_req_header("content-type", "application/json")
        |> router_call()

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["image"] == "ubuntu:24.04"

      Manager.close(body["session_id"])
    end
  end

  # ── POST /sessions/:id/exec ──────────────────────────────────

  describe "POST /sessions/:id/exec" do
    setup do
      {:ok, session} = Manager.create("test-agent", "ubuntu:24.04")
      on_exit(fn -> Manager.close(session.id) end)
      {:ok, session_id: session.id}
    end

    test "executes command in session", %{session_id: sid} do
      conn =
        conn(:post, "/sessions/#{sid}/exec", %{cmd: ["echo", "session exec works"]})
        |> put_req_header("content-type", "application/json")
        |> router_call()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["exit_code"] == 0
      assert body["stdout"] =~ "session exec works"
      assert body["session_id"] == sid
    end

    test "returns 404 for unknown session" do
      conn =
        conn(:post, "/sessions/nonexistent/exec", %{cmd: ["echo", "hi"]})
        |> put_req_header("content-type", "application/json")
        |> router_call()

      assert conn.status == 404
    end

    test "returns 410 for closed session", %{session_id: sid} do
      Manager.close(sid)

      conn =
        conn(:post, "/sessions/#{sid}/exec", %{cmd: ["echo", "hi"]})
        |> put_req_header("content-type", "application/json")
        |> router_call()

      assert conn.status == 410
    end
  end

  # ── GET /sessions/:id ────────────────────────────────────────

  describe "GET /sessions/:id" do
    setup do
      {:ok, session} = Manager.create("test-agent", "ubuntu:24.04")
      on_exit(fn -> Manager.close(session.id) end)
      {:ok, session_id: session.id}
    end

    test "returns session details", %{session_id: sid} do
      conn = router_call(conn(:get, "/sessions/#{sid}"))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["session_id"] == sid
      assert body["status"] == "running"
      assert body["agent_id"] == "test-agent"
      assert body["created_at"] != nil
    end

    test "returns 404 for unknown session" do
      conn = router_call(conn(:get, "/sessions/nonexistent"))
      assert conn.status == 404
    end
  end

  # ── GET /sessions (list) ─────────────────────────────────────

  describe "GET /sessions" do
    test "returns session list" do
      conn = router_call(conn(:get, "/sessions"))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["sessions"])
      assert is_integer(body["count"])
    end
  end

  # ── DELETE /sessions/:id ─────────────────────────────────────

  describe "DELETE /sessions/:id" do
    test "closes a session" do
      {:ok, session} = Manager.create("test-agent", "ubuntu:24.04")

      conn = router_call(conn(:delete, "/sessions/#{session.id}"))
      assert conn.status == 200

      # Verify closed
      {:error, :not_found} = Manager.get(session.id)
    end

    test "returns 404 for nonexistent session" do
      conn = router_call(conn(:delete, "/sessions/nonexistent"))
      assert conn.status == 404
    end
  end

  # ── GET /sessions/stats ──────────────────────────────────────

  describe "GET /sessions/stats" do
    test "returns session statistics" do
      conn = router_call(conn(:get, "/sessions/stats"))
      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)
      assert is_integer(body["total"])
      assert is_integer(body["running"])
      assert is_map(body["by_image"])
    end
  end

  # ── POST /images/:ref/warm ───────────────────────────────────

  describe "POST /images/:ref/warm" do
    test "accepts warm request" do
      conn =
        conn(:post, "/images/ubuntu:24.04/warm", %{count: 2})
        |> put_req_header("content-type", "application/json")
        |> router_call()

      assert conn.status == 202
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "warming"
      assert body["image"] == "ubuntu:24.04"
      assert body["requested"] == 2
    end

    test "caps count at 10" do
      conn =
        conn(:post, "/images/ubuntu:24.04/warm", %{count: 100})
        |> put_req_header("content-type", "application/json")
        |> router_call()

      body = Jason.decode!(conn.resp_body)
      assert body["requested"] == 10
    end
  end

  # ── GET /images/:ref/warm-status ─────────────────────────────

  describe "GET /images/:ref/warm-status" do
    test "returns warm status" do
      conn = router_call(conn(:get, "/images/ubuntu:24.04/warm-status"))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["image"] == "ubuntu:24.04"
      assert is_integer(body["warm_vms"])
      assert is_map(body["pool_stats"])
    end
  end

  # ── GET /pool/stats ──────────────────────────────────────────

  describe "GET /pool/stats" do
    test "returns pool statistics" do
      conn = router_call(conn(:get, "/pool/stats"))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_integer(body["warm"])
      assert is_integer(body["total"])
      assert is_map(body["metrics"])
    end
  end

  # ── Helpers ──────────────────────────────────────────────────

  defp router_call(conn) do
    Router.call(conn, @opts)
  end
end
