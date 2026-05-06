defmodule Zypi.Integration.SessionTest do
  @moduledoc """
  Integration tests for session lifecycle.
  Requires a running Zypi instance with warm VMs.
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  @base_url "http://localhost:4000"

  setup do
    case Req.get("#{@base_url}/health", receive_timeout: 2000) do
      {:ok, %{status: 200}} -> :ok
      _ -> raise "Zypi not reachable"
    end
    :ok
  end

  describe "session lifecycle" do
    test "create, exec, close" do
      create_resp = Req.post!("#{@base_url}/sessions",
        json: %{image: "ubuntu:24.04", agent_id: "test-agent"})
      assert create_resp.status == 201
      session_id = create_resp.body["session_id"]

      exec_resp = Req.post!("#{@base_url}/sessions/#{session_id}/exec",
        json: %{cmd: ["echo", "session test"]})
      assert exec_resp.body["exit_code"] == 0
      assert exec_resp.body["stdout"] =~ "session test"

      exec2 = Req.post!("#{@base_url}/sessions/#{session_id}/exec",
        json: %{cmd: ["sh", "-c", "echo step2 >> /tmp/steps; cat /tmp/steps"]})
      assert exec2.body["stdout"] =~ "step2"

      Req.delete!("#{@base_url}/sessions/#{session_id}")
      get_after = Req.get("#{@base_url}/sessions/#{session_id}")
      assert get_after.status == 404
    end

    test "multi-step pip install + use" do
      create = Req.post!("#{@base_url}/sessions",
        json: %{image: "ubuntu:24.04", agent_id: "workflow"})
      sid = create.body["session_id"]

      install = Req.post!("#{@base_url}/sessions/#{sid}/exec",
        json: %{cmd: ["pip3", "install", "six"], timeout: 30})
      assert install.body["exit_code"] == 0

      use = Req.post!("#{@base_url}/sessions/#{sid}/exec",
        json: %{cmd: ["python3", "-c", "import six; print(six.__version__)"]})
      assert use.body["exit_code"] == 0

      Req.delete!("#{@base_url}/sessions/#{sid}")
    end
  end
end
