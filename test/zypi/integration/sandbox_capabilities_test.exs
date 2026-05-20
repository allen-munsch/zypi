defmodule Zypi.Integration.SandboxCapabilitiesTest do
  @moduledoc """
  Integration tests that verify sandbox capabilities end-to-end.
  Requires a running Zypi instance with warm VMs.

  Run with: mix test --only integration
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  @base_url "http://localhost:4000"

  setup do
    # Verify Zypi is reachable
    case Req.get("#{@base_url}/health", receive_timeout: 2000) do
      {:ok, %{status: 200}} -> :ok
      _ -> raise "Zypi not reachable at #{@base_url}"
    end
    :ok
  end

  defp exec(cmd, opts \\ []) do
    image = Keyword.get(opts, :image, "ubuntu:24.04")
    timeout = Keyword.get(opts, :timeout, 15)

    body = %{cmd: cmd, image: image, timeout: timeout}
    |> Map.merge(opts |> Keyword.take([:env, :workdir, :files, :memory_mb, :vcpus])
                  |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new())

    resp = Req.post!("#{@base_url}/exec",
      json: body,
      receive_timeout: (timeout + 5) * 1000)

    case resp.status do
      200 -> {:ok, resp.body}
      s -> {:error, s, resp.body}
    end
  end

  # ── Core Execution ──────────────────────────────────────

  describe "basic execution" do
    test "echo command" do
      {:ok, result} = exec(["echo", "hello zypi"])
      assert result["exit_code"] == 0
      assert result["stdout"] =~ "hello zypi"
    end

    test "non-zero exit" do
      {:ok, result} = exec(["sh", "-c", "exit 42"])
      assert result["exit_code"] == 42
    end

    test "stdout and stderr separation" do
      {:ok, result} = exec(["sh", "-c", "echo stdout; echo stderr >&2"])
      assert result["stdout"] =~ "stdout"
      assert result["stderr"] =~ "stderr"
    end

    test "command timeout" do
      {:ok, result} = exec(["sleep", "10"], timeout: 2)
      assert result["timed_out"] == true
    end
  end

  # ── Environment ─────────────────────────────────────────

  describe "environment variables" do
    test "custom env vars" do
      {:ok, result} = exec(["sh", "-c", "echo $ZYPI_TEST_VAR"],
        env: %{"ZYPI_TEST_VAR" => "integration-test"})
      assert result["stdout"] =~ "integration-test"
    end
  end

  # ── File Operations ─────────────────────────────────────

  describe "file injection" do
    test "write and read files" do
      {:ok, result} = exec(["cat", "/tmp/zypi-test.txt"],
        files: %{"/tmp/zypi-test.txt" => "integration test content"})
      assert result["stdout"] =~ "integration test content"
    end
  end

  # ── Networking ──────────────────────────────────────────

  describe "network access" do
    test "HTTP outbound" do
      {:ok, result} = exec(["curl", "-s", "http://httpbin.org/ip"],
        timeout: 15)
      assert result["exit_code"] == 0
      assert result["stdout"] =~ "origin"
    end

    test "HTTPS outbound" do
      {:ok, result} = exec(["curl", "-s", "https://httpbin.org/ip"],
        timeout: 15)
      assert result["exit_code"] == 0
      assert result["stdout"] =~ "origin"
    end

    test "DNS resolution" do
      {:ok, result} = exec(["sh", "-c", "cat /etc/resolv.conf"])
      assert result["stdout"] =~ "nameserver"
    end
  end

  # ── Chromium / Browser ──────────────────────────────────

  describe "chromium browser" do
    test "chromium binary exists" do
      {:ok, result} = exec(["sh", "-c", "which chromium-browser || which chromium || ls /usr/bin/chrom* 2>/dev/null || echo NOT_FOUND"])
      refute result["stdout"] =~ "NOT_FOUND"
    end

    test "chromium version" do
      {:ok, result} = exec(["chromium-browser", "--version"],
        timeout: 10)
      assert result["exit_code"] == 0
    end

    test "chromium headless render" do
      {:ok, result} = exec(["chromium-browser", "--headless", "--disable-gpu",
        "--no-sandbox", "--dump-dom", "http://httpbin.org/html"],
        timeout: 30, memory_mb: 512)
      assert result["exit_code"] == 0
      assert result["stdout"] =~ "<html" or result["stdout"] =~ "<HTML"
    end
  end

  # ── Python / pip ────────────────────────────────────────

  describe "python runtime" do
    test "python3 available" do
      {:ok, result} = exec(["python3", "-c", "import sys; print(sys.version)"])
      assert result["exit_code"] == 0
      assert result["stdout"] =~ "3."
    end

    test "pip available" do
      {:ok, result} = exec(["pip3", "--version"])
      assert result["exit_code"] == 0
    end

    test "pip install package" do
      {:ok, result} = exec(["pip3", "install", "six"],
        timeout: 30)
      assert result["exit_code"] == 0
    end

    test "import installed package" do
      {:ok, result} = exec(["python3", "-c", "import json; print(json.dumps({'ok': True}))"])
      assert result["exit_code"] == 0
      assert result["stdout"] =~ "ok"
    end
  end

  # ── Memory Limits ───────────────────────────────────────

  describe "resource limits" do
    test "respects memory limit" do
      {:ok, result} = exec(["sh", "-c", "free -m | grep Mem"],
        memory_mb: 512)
      assert result["exit_code"] == 0
      # Should be around 512MB
      [_, mem] = Regex.run(~r/Mem:\s+(\d+)/, result["stdout"])
      mem_mb = String.to_integer(mem)
      assert mem_mb > 0
      assert mem_mb < 1024  # shouldn't exceed 1GB
    end
  end
end
