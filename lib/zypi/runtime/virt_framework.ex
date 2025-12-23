defmodule Zypi.Runtime.VirtFramework do
  @moduledoc """
  Apple Virtualization.framework runtime for macOS 11+.
  
  Uses a Swift helper binary (`zypi-virt`) that wraps Virtualization.framework.
  Supports both Intel and Apple Silicon Macs.
  """

  @behaviour Zypi.Runtime.Behaviour
  require Logger

  @data_dir Application.compile_env(:zypi, :data_dir, "~/.zypi") |> Path.expand()
  @vm_dir Path.join(@data_dir, "vms")
  @helper_path Application.compile_env(:zypi, :virt_helper_path, "/usr/local/bin/zypi-virt")

  @impl true
  def available? do
    cond do
      :os.type() != {:unix, :darwin} ->
        false
      not macos_version_ok?() ->
        Logger.debug("VirtFramework: Requires macOS 11+")
        false
      not helper_installed?() ->
        Logger.debug("VirtFramework: zypi-virt helper not found")
        false
      true ->
        true
    end
  end

  @impl true
  def name, do: "Virtualization.framework"

  defp macos_version_ok? do
    case System.cmd("sw_vers", ["-productVersion"], stderr_to_stdout: true) do
      {version, 0} ->
        [major | _] = version |> String.trim() |> String.split(".")
        String.to_integer(major) >= 11
      _ -> false
    end
  end

  defp helper_installed? do
    File.exists?(@helper_path) or System.find_executable("zypi-virt") != nil
  end

  @impl true
  def start(container) do
    Logger.info("VirtFramework: Starting VM for #{container.id}")

    vm_path = Path.join(@vm_dir, container.id)
    File.mkdir_p!(vm_path)

    config_path = Path.join(vm_path, "config.json")
    socket_path = Path.join(vm_path, "control.sock")

    # Write VM config
    config = %{
      id: container.id,
      rootfs: container.rootfs,
      kernel: kernel_path(),
      memory_mb: get_in(container.resources, [:memory_mb]) || 256,
      cpus: get_in(container.resources, [:cpu]) || 1,
      ip: format_ip(container.ip),
      socket_path: socket_path
    }
    File.write!(config_path, Jason.encode!(config))

    # Start helper process
    port = Port.open({:spawn_executable, helper_path()}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: ["start", "--config", config_path]
    ])

    # Wait for VM to be ready
    case wait_for_socket(socket_path) do
      :ok ->
        {:ok, %{
          socket_path: socket_path,
          pid: port,
          config_path: config_path,
          container_ip: container.ip
        }}
      {:error, reason} ->
        safe_close_port(port)
        {:error, reason}
    end
  end

  @impl true
  def stop(%{id: id, pid: vm_state}) when is_map(vm_state) do
    Logger.info("VirtFramework: Stopping VM #{id}")

    # Send stop command via socket
    if vm_state.socket_path && File.exists?(vm_state.socket_path) do
      send_command(vm_state.socket_path, "stop")
    end

    Process.sleep(500)
    safe_close_port(vm_state.pid)
    cleanup(id)
    :ok
  end

  def stop(%{id: id}), do: cleanup(id)

  @impl true
  def exec(container_id, cmd, opts) do
    Zypi.Container.Agent.exec(container_id, cmd, opts)
  end

  @impl true
  def health(container_id) do
    Zypi.Container.Agent.health(container_id)
  end

  @impl true
  def cleanup(container_id) do
    vm_path = Path.join(@vm_dir, container_id)
    
    # Kill any running helper
    System.cmd("pkill", ["-f", "zypi-virt.*#{container_id}"], stderr_to_stdout: true)
    
    File.rm_rf(vm_path)
    :ok
  end

  @impl true
  def setup_network(container_id, ip) do
    # macOS uses vmnet.framework for networking
    # The helper handles this internally
    {:ok, %{mode: :vmnet, container_id: container_id, ip: ip}}
  end

  @impl true
  def teardown_network(_container_id, _state) do
    # vmnet cleanup is handled by the helper
    :ok
  end

  # Private functions

  defp wait_for_socket(path, attempts \\ 100) do
    cond do
      File.exists?(path) -> :ok
      attempts <= 0 -> {:error, :socket_timeout}
      true -> Process.sleep(50); wait_for_socket(path, attempts - 1)
    end
  end

  defp send_command(socket_path, command) do
    case :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: false], 5000) do
      {:ok, socket} ->
        :gen_tcp.send(socket, Jason.encode!(%{command: command}) <> "\n")
        result = :gen_tcp.recv(socket, 0, 5000)
        :gen_tcp.close(socket)
        result
      error -> error
    end
  end

  defp kernel_path do
    Application.get_env(:zypi, :kernel_path)
  end

  defp helper_path do
    System.find_executable("zypi-virt") || @helper_path
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip) when is_binary(ip), do: ip

  defp safe_close_port(port) when is_port(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end
  defp safe_close_port(_), do: :ok
end
