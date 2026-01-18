defmodule Zypi.Runtime.QEMU do
  @moduledoc """
  QEMU runtime - cross-platform fallback.
  
  Uses hardware acceleration when available:
  - Linux: KVM
  - macOS: HVF (Hypervisor.framework)
  - Windows: WHPX (Windows Hypervisor Platform)
  """

  @behaviour Zypi.Runtime.Behaviour
  require Logger

  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")
  @vm_dir Path.join(@data_dir, "vms")

  @impl true
  def available? do
    qemu_installed?()
  end

  @impl true
  def name, do: "QEMU"

  defp qemu_installed? do
    System.find_executable("qemu-system-x86_64") != nil or
    System.find_executable("qemu-system-aarch64") != nil
  end

  defp qemu_binary do
    arch = to_string(:erlang.system_info(:system_architecture))
    if String.contains?(arch, "arm") or String.contains?(arch, "aarch64") do
      System.find_executable("qemu-system-aarch64") || "qemu-system-aarch64"
    else
      System.find_executable("qemu-system-x86_64") || "qemu-system-x86_64"
    end
  end

  defp accel_args do
    case :os.type() do
      {:unix, :linux} ->
        if File.exists?("/dev/kvm"), do: ["-accel", "kvm"], else: ["-accel", "tcg"]
      {:unix, :darwin} ->
        ["-accel", "hvf"]
      {:win32, _} ->
        ["-accel", "whpx"]
      _ ->
        ["-accel", "tcg"]
    end
  end

  @impl true
  def start(container) do
    Logger.info("QEMU: Starting VM for #{container.id}")

    vm_path = Path.join(@vm_dir, container.id)
    File.mkdir_p!(vm_path)

    pid_file = Path.join(vm_path, "qemu.pid")
    monitor_socket = Path.join(vm_path, "monitor.sock")
    serial_socket = Path.join(vm_path, "serial.sock")

    mem_mb = get_in(container.resources, [:memory_mb]) || 256
    cpus = get_in(container.resources, [:cpu]) || 1
    {a, b, c, d} = container.ip
    ip_str = "#{a}.#{b}.#{c}.#{d}"

    args = accel_args() ++ [
      "-m", "#{mem_mb}M",
      "-smp", "#{cpus}",
      "-kernel", kernel_path(),
      "-drive", "file=#{container.rootfs},format=raw,if=virtio",
      "-append", "console=ttyS0 root=/dev/vda rw init=/sbin/init ip=#{ip_str}::10.0.0.1:255.255.255.0::eth0:off",
      "-netdev", "user,id=net0,hostfwd=tcp::#{agent_port(container.id)}-:9999",
      "-device", "virtio-net-pci,netdev=net0",
      "-nographic",
      "-serial", "unix:#{serial_socket},server,nowait",
      "-monitor", "unix:#{monitor_socket},server,nowait",
      "-pidfile", pid_file,
      "-daemonize"
    ]

    case System.cmd(qemu_binary(), args, stderr_to_stdout: true) do
      {_, 0} ->
        # Wait for QEMU to start
        Process.sleep(500)
        
        {:ok, %{
          socket_path: monitor_socket,
          serial_socket: serial_socket,
          pid_file: pid_file,
          pid: nil,
          container_ip: container.ip,
          agent_port: agent_port(container.id)
        }}
        
      {output, code} ->
        Logger.error("QEMU start failed (#{code}): #{output}")
        {:error, {:qemu_failed, code, output}}
    end
  end

  @impl true
  def stop(%{id: id, pid: vm_state}) when is_map(vm_state) do
    Logger.info("QEMU: Stopping VM #{id}")

    # Send quit command via monitor
    if vm_state[:socket_path] && File.exists?(vm_state.socket_path) do
      send_monitor_command(vm_state.socket_path, "quit")
    end

    # Also try to kill by PID file
    if vm_state[:pid_file] && File.exists?(vm_state.pid_file) do
      case File.read(vm_state.pid_file) do
        {:ok, pid_str} ->
          pid = String.trim(pid_str)
          System.cmd("kill", [pid], stderr_to_stdout: true)
        _ -> :ok
      end
    end

    cleanup(id)
    :ok
  end

  def stop(%{id: id}), do: cleanup(id)

  @impl true
  def exec(container_id, cmd, opts) do
    # For QEMU with user-mode networking, we connect to the forwarded port
    port = agent_port(container_id)
    
    # Override the agent to use localhost with forwarded port
    opts = Keyword.put(opts, :port, port)
    opts = Keyword.put(opts, :host, "127.0.0.1")
    
    Zypi.Container.Agent.exec(container_id, cmd, opts)
  end

  @impl true
  def health(container_id) do
    port = agent_port(container_id)
    Zypi.Container.Agent.call_with_host(container_id, "health", %{},
      host: "127.0.0.1", port: port)
  end

  @impl true
  def cleanup(container_id) do
    vm_path = Path.join(@vm_dir, container_id)
    
    # Kill QEMU process
    System.cmd("pkill", ["-f", "qemu.*#{container_id}"], stderr_to_stdout: true)
    
    File.rm_rf(vm_path)
    :ok
  end

  @impl true
  def setup_network(_container_id, _ip) do
    # QEMU user-mode networking handles this
    {:ok, %{mode: :user}}
  end

  @impl true
  def teardown_network(_container_id, _state) do
    :ok
  end

  # Private functions

  defp kernel_path do
    Application.get_env(:zypi, :kernel_path)
  end

  defp agent_port(container_id) do
    # Generate consistent port from container ID
    10000 + :erlang.phash2(container_id, 50000)
  end

  defp send_monitor_command(socket_path, command) do
    case :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: false], 2000) do
      {:ok, socket} ->
        :gen_tcp.send(socket, "#{command}\n")
        :gen_tcp.close(socket)
        :ok
      _ -> :ok
    end
  end
end
