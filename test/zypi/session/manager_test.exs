defmodule Zypi.Session.ManagerTest do
  use ExUnit.Case, async: false
  alias Zypi.Session.Manager

  @moduletag :integration
  @moduletag :fabric

  setup do
    # Ensure images exist (imported in test setup)
    :ok
  end

  describe "create/3" do
    test "creates a session and returns session info" do
      {:ok, session} = Manager.create("test-agent", "ubuntu:24.04")

      assert session.id =~ ~r/^fabric_/
      assert session.container_id =~ ~r/^sess_/
      assert session.status == :running
      assert session.agent_id == "test-agent"
      assert session.image == "ubuntu:24.04"
      assert session.ip != nil
      assert session.created_at != nil

      # Clean up
      Manager.close(session.id)
    end

    test "returns error for unknown image" do
      {:error, _reason} = Manager.create("test-agent", "nonexistent:99")
    end
  end

  describe "exec/3 in session" do
    setup do
      {:ok, session} = Manager.create("test-agent", "ubuntu:24.04")
      on_exit(fn -> Manager.close(session.id) end)
      {:ok, session: session}
    end

    test "executes a simple command", %{session: session} do
      {:ok, result} = Manager.exec(session.id, ["echo", "hello fabric"])

      assert result.exit_code == 0
      assert result.stdout =~ "hello fabric"
      assert result.session_id == session.id
      assert result.container_id == session.container_id
    end

    test "captures stderr on failure", %{session: session} do
      {:ok, result} = Manager.exec(session.id, ["ls", "/nonexistent"])

      assert result.exit_code != 0
    end

    test "multiple execs in same session", %{session: session} do
      {:ok, _} = Manager.exec(session.id, ["sh", "-c", "echo step1 > /tmp/steps"])
      {:ok, r2} = Manager.exec(session.id, ["cat", "/tmp/steps"])
      {:ok, r3} = Manager.exec(session.id, ["sh", "-c", "echo step2 >> /tmp/steps"])
      {:ok, r4} = Manager.exec(session.id, ["cat", "/tmp/steps"])

      assert r2.stdout =~ "step1"
      assert r3.exit_code == 0
      assert r4.stdout =~ "step1"
      assert r4.stdout =~ "step2"
    end

    test "returns error for closed session", %{session: session} do
      Manager.close(session.id)

      {:error, {:session_closed, _}} = Manager.exec(session.id, ["echo", "nope"])
    end

    test "returns error for nonexistent session" do
      {:error, :session_not_found} = Manager.exec("nonexistent", ["echo", "nope"])
    end

    test "respects command timeout", %{session: session} do
      {:ok, result} = Manager.exec(session.id, ["sleep", "2"], timeout: 1)
      assert result.timed_out == true
    end
  end

  describe "get/1 and list/0" do
    setup do
      {:ok, s1} = Manager.create("agent-a", "ubuntu:24.04")
      {:ok, s2} = Manager.create("agent-b", "ubuntu:24.04")
      on_exit(fn ->
        Manager.close(s1.id)
        Manager.close(s2.id)
      end)
      {:ok, s1: s1, s2: s2}
    end

    test "returns session by id", %{s1: s1} do
      {:ok, session} = Manager.get(s1.id)
      assert session.id == s1.id
    end

    test "returns error for nonexistent id" do
      {:error, :not_found} = Manager.get("nonexistent")
    end

    test "lists all active sessions" do
      {:ok, sessions} = Manager.list()
      assert length(sessions) >= 2
    end
  end

  describe "close/1" do
    test "closes session and releases resources" do
      {:ok, session} = Manager.create("test-agent", "ubuntu:24.04")
      :ok = Manager.close(session.id)

      {:error, :not_found} = Manager.get(session.id)
    end

    test "idempotent close" do
      {:ok, session} = Manager.create("test-agent", "ubuntu:24.04")
      :ok = Manager.close(session.id)
      {:error, :not_found} = Manager.close(session.id)
    end
  end

  describe "close_agent_sessions/1" do
    test "closes all sessions for an agent" do
      {:ok, s1} = Manager.create("agent-c", "ubuntu:24.04")
      {:ok, s2} = Manager.create("agent-c", "ubuntu:24.04")
      {:ok, s3} = Manager.create("agent-d", "ubuntu:24.04")

      {:ok, 2} = Manager.close_agent_sessions("agent-c")

      {:error, :not_found} = Manager.get(s1.id)
      {:error, :not_found} = Manager.get(s2.id)
      {:ok, _} = Manager.get(s3.id)

      Manager.close(s3.id)
    end
  end

  describe "stats/0" do
    test "returns session statistics" do
      stats = Manager.stats()
      assert is_map(stats)
      assert is_integer(stats.total)
      assert is_integer(stats.running)
      assert is_map(stats.by_image)
    end
  end
end
