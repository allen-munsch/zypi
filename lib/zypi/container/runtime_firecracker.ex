defmodule Zypi.Container.RuntimeFirecracker do
  @moduledoc """
  Firecracker microVM runtime for Zypi containers.
  """
  require Logger
  alias Zypi.Container.Console

  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")
  @vm_dir Path.join(@data_dir, "vms")
  @kernel_path Application.compile_env(:zypi, :kernel_path, "/opt/zypi/kernel/vmlinux")
  @initrd_path Application.compile_env(:zypi, :initrd_path, "/opt/zypi/kernel/initramfs.img")

  defmodule VMState do
    defstruct [:socket_path, :fc_port, :tap_device, :container_ip]
  end

  def start(container) do
    Logger.info("Starting Firecracker VM for #{container.id}")

    vm_path = Path.join(@vm_dir, container.id)
    File.mkdir_p!(vm_path)
    socket_path = Path.join(vm_path, "api.sock")
    File.rm(socket_path)

    # Generate tap name early so we can use it in error handling
    tap_name = "ztap#{:erlang.phash2(container.id, 9999)}"

    with {:ok, tap} <- setup_tap(container.id, container.ip),
         {:ok, fc_port} <- spawn_firecracker(socket_path),
         :ok <- wait_for_socket(socket_path),
         :ok <- configure_vm(socket_path, container, tap),
         :ok <- connect_vm_to_network(container.id, container.ip, tap),
         :ok <- start_instance(socket_path) do

      # Stop any existing console for this container (cleanup from previous runs)
      Zypi.Container.Console.stop(container.id)

      # Small delay to ensure cleanup completes
      Process.sleep(50)

      # Start fresh console
      case Zypi.Container.Console.start_link(container.id, fc_port) do
        {:ok, _console_pid} ->
          Logger.info("Console started for #{container.id}")
          {:ok, %VMState{
            socket_path: socket_path,
            fc_port: fc_port,
            tap_device: tap,
            container_ip: container.ip
          }}

        {:error, {:already_started, existing_pid}} ->
          Logger.warning("Console for #{container.id} already existed (PID: #{inspect(existing_pid)}), stopping and retrying")
          # Force stop and retry once
          try do
            GenServer.stop(existing_pid, :normal, 1000)
          rescue
            _ -> nil
          end

          Process.sleep(100)

          case Zypi.Container.Console.start_link(container.id, fc_port) do
            {:ok, _pid} ->
              {:ok, %VMState{
                socket_path: socket_path,
                fc_port: fc_port,
                tap_device: tap,
                container_ip: container.ip
              }}
            {:error, reason} ->
              Logger.error("Console retry failed: #{inspect(reason)}")
              cleanup_with_network(container.id, container.ip, tap)
              {:error, {:console_failed, reason}}
          end

        {:error, reason} ->
          Logger.error("Failed to start console for #{container.id}: #{inspect(reason)}")
          cleanup_with_network(container.id, container.ip, tap)
          {:error, {:console_failed, reason}}
      end
    else
      {:error, reason} ->
        Logger.error("VM start failed for #{container.id}: #{inspect(reason)}")
        # Try to clean up using the pre-generated tap name
        cleanup_with_network(container.id, container.ip, tap_name)
        {:error, reason}
    end
  end

  def stop(%{id: id, pid: %VMState{} = state}) do
    Logger.info("Stopping VM #{id}")

    # Try graceful shutdown first
    try do
      api_request(state.socket_path, :put, "/actions", %{action_type: "SendCtrlAltDel"})
    rescue
      _ -> :ok
    end

    Process.sleep(500)
    safe_close_port(state.fc_port)

    # Clean up network rules
    disconnect_vm_from_network(id, state.container_ip, state.tap_device)

    # Clean up everything else
    cleanup(id)
    :ok
  end

  def stop(%{id: id}), do: cleanup(id)

  def cleanup_rootfs(container_id), do: cleanup(container_id)

  def spawn_firecracker(socket_path) do
    port = Port.open({:spawn_executable, firecracker_path()}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: ["--api-sock", socket_path]
    ])
    Process.sleep(100)
    {:ok, port}
  end

  def wait_for_socket(path, attempts \\ 100) do
    cond do
      File.exists?(path) -> :ok
      attempts <= 0 -> {:error, :socket_timeout}
      true -> Process.sleep(10); wait_for_socket(path, attempts - 1)
    end
  end

  def configure_vm(socket_path, container, tap) do
    # The rootfs is now expected to be a TCMU device path from the snapshot
    rootfs_path = container.rootfs

    Logger.info("RuntimeFirecracker: Using rootfs device: #{rootfs_path}")
    Logger.info("RuntimeFirecracker: Using kernel: #{@kernel_path}")

    vm_path = Path.join(@vm_dir, container.id)
    File.write!(Path.join(vm_path, "serial.log"), "")

    mem_mb = get_in(container.resources, [:memory_mb]) || 256
    vcpus = get_in(container.resources, [:cpu]) || 1
    {a, b, c, d} = container.ip
    ip_str = "#{a}.#{b}.#{c}.#{d}"
    gateway = "#{a}.#{b}.#{c}.1"

    boot_args = [
      "console=ttyS0",
      "reboot=k",
      "panic=1",
      "pci=off",
      "root=/dev/vda",
      # "random.trust_cpu=on", # TODO, virtio-rng entropy isn't in quickstart kernel, crng?
      "rw",
      "init=/sbin/init",
      "ip=#{ip_str}::#{gateway}:255.255.255.0::eth0:off"
    ] |> Enum.join(" ")

    with :ok <- api_request(socket_path, :put, "/boot-source", %{
          kernel_image_path: @kernel_path,
          boot_args: boot_args
        }),
        :ok <- api_request(socket_path, :put, "/machine-config", %{
          vcpu_count: vcpus,
          mem_size_mib: mem_mb,
          smt: false
        }),
        :ok <- api_request(socket_path, :put, "/drives/rootfs", %{
          drive_id: "rootfs",
          path_on_host: rootfs_path,
          is_root_device: true,
          is_read_only: false
        }),
        :ok <- api_request(socket_path, :put, "/entropy", %{rate_limiter: nil}),
        :ok <- api_request(socket_path, :put, "/network-interfaces/eth0", %{
          iface_id: "eth0",
          host_dev_name: tap,
          guest_mac: mac_for_id(container.id)
        }) do
      :ok
    end
  end

  def start_instance(socket_path) do
    api_request(socket_path, :put, "/actions", %{action_type: "InstanceStart"})
  end

  def api_request(socket_path, method, path, body) do
    json = Jason.encode!(body)
    method_str = method |> Atom.to_string() |> String.upcase()

    request = """
    #{method_str} #{path} HTTP/1.1\r
    Host: localhost\r
    Content-Type: application/json\r
    Content-Length: #{byte_size(json)}\r
    \r
    #{json}
    """

    case :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: false], 5000) do
      {:ok, socket} ->
        :ok = :gen_tcp.send(socket, request)
        result = case :gen_tcp.recv(socket, 0, 5000) do
          {:ok, response} ->
            if response =~ ~r/HTTP\/1\.[01] (200|204)/ do
              :ok
            else
              {:error, {:http_error, response}}
            end
          {:error, reason} ->
            {:error, {:recv_error, reason}}
        end
        :gen_tcp.close(socket)
        result
      {:error, reason} ->
        {:error, {:connect_error, reason}}
    end
  end

  def setup_tap(container_id, ip) do
    setup_bridge()
    tap_name = "ztap#{:erlang.phash2(container_id, 9999)}"
    bridge_name = "zypi0"

    # Create TAP device
    System.cmd("ip", ["tuntap", "add", tap_name, "mode", "tap"], stderr_to_stdout: true)
    System.cmd("ip", ["link", "set", tap_name, "up"], stderr_to_stdout: true)
    System.cmd("ip", ["link", "set", tap_name, "promisc", "on"], stderr_to_stdout: true)

    # Add TAP to bridge
    System.cmd("ip", ["link", "set", tap_name, "master", bridge_name], stderr_to_stdout: true)

    # IP forwarding (ensure it's enabled)
    System.cmd("sysctl", ["-w", "net.ipv4.ip_forward=1"], stderr_to_stdout: true)

    {:ok, tap_name}
  end

  @doc """
  Connect VM to bridge network and set up firewall rules.
  """
  def connect_vm_to_network(container_id, container_ip, tap_device) do
    {a, b, c, d} = container_ip
    ip_str = "#{a}.#{b}.#{c}.#{d}"

    Logger.info("Connecting VM #{container_id} (#{ip_str}) to network via #{tap_device}")

    # 1. Ensure IP forwarding is enabled
    System.cmd("sysctl", ["-w", "net.ipv4.ip_forward=1"], stderr_to_stdout: true)

    # 2. Set up bridge if not exists
    setup_bridge()

    # 3. Add iptables rules
    rules = [
      # Allow established connections
      ["-A", "FORWARD", "-m", "conntrack", "--ctstate", "RELATED,ESTABLISHED", "-j", "ACCEPT"],

      # Allow traffic from bridge to TAP
      ["-A", "FORWARD", "-i", "zypi0", "-o", tap_device, "-j", "ACCEPT"],

      # Allow traffic from TAP to bridge
      ["-A", "FORWARD", "-i", tap_device, "-o", "zypi0", "-j", "ACCEPT"],

      # NAT for outbound traffic from VM
      ["-t", "nat", "-A", "POSTROUTING", "-s", "#{ip_str}/24", "-j", "MASQUERADE"],

      # Allow SSH specifically
      ["-A", "INPUT", "-i", "zypi0", "-p", "tcp", "--dport", "22", "-j", "ACCEPT"],
      ["-A", "FORWARD", "-i", "zypi0", "-p", "tcp", "--dport", "22", "-j", "ACCEPT"]
    ]

    # Apply each rule
    Enum.each(rules, fn rule ->
      System.cmd("iptables", rule, stderr_to_stdout: true)
    end)

    Logger.info("Network rules set up for #{container_id}")
    :ok
  end

  @doc """
  Remove firewall rules when VM is stopped.
  """
  def disconnect_vm_from_network(container_id, container_ip, tap_device) do
    {a, b, c, d} = container_ip
    ip_str = "#{a}.#{b}.#{c}.#{d}"

    Logger.info("Disconnecting VM #{container_id} from network")

    rules = [
      # Remove forward rules
      ["-D", "FORWARD", "-m", "conntrack", "--ctstate", "RELATED,ESTABLISHED", "-j", "ACCEPT"],
      ["-D", "FORWARD", "-i", "zypi0", "-o", tap_device, "-j", "ACCEPT"],
      ["-D", "FORWARD", "-i", tap_device, "-o", "zypi0", "-j", "ACCEPT"],

      # Remove NAT rule
      ["-t", "nat", "-D", "POSTROUTING", "-s", "#{ip_str}/24", "-j", "MASQUERADE"],

      # Remove SSH rules
      ["-D", "INPUT", "-i", "zypi0", "-p", "tcp", "--dport", "22", "-j", "ACCEPT"],
      ["-D", "FORWARD", "-i", "zypi0", "-p", "tcp", "--dport", "22", "-j", "ACCEPT"]
    ]

    # Try to remove each rule (ignore errors for rules that don't exist)
    Enum.each(rules, fn rule ->
      {_output, exit_code} = System.cmd("iptables", rule, stderr_to_stdout: true)
      if exit_code != 0 do
        Logger.debug("Rule removal failed (may not exist): #{inspect(rule)}")
      end
    end)

    # Remove TAP device
    System.cmd("ip", ["link", "del", tap_device], stderr_to_stdout: true)

    :ok
  end

  @doc """
  Set up the zypi0 bridge if it doesn't exist.
  """
  def setup_bridge() do
    # Check if bridge exists
    {output, exit_code} = System.cmd("ip", ["link", "show", "zypi0"], stderr_to_stdout: true)

    if exit_code != 0 do
      Logger.info("Creating zypi0 bridge")
      System.cmd("ip", ["link", "add", "name", "zypi0", "type", "bridge"], stderr_to_stdout: true)
      System.cmd("ip", ["addr", "add", "10.0.0.1/24", "dev", "zypi0"], stderr_to_stdout: true)
      System.cmd("ip", ["link", "set", "zypi0", "up"], stderr_to_stdout: true)

      # Enable IP forwarding for the bridge
      System.cmd("iptables", ["-A", "FORWARD", "-i", "zypi0", "-j", "ACCEPT"], stderr_to_stdout: true)
      System.cmd("iptables", ["-A", "FORWARD", "-o", "zypi0", "-j", "ACCEPT"], stderr_to_stdout: true)
    end

    :ok
  end

  @doc """
  Clean up with network disconnection.
  """
  def cleanup_with_network(container_id, container_ip, tap_device) do
    disconnect_vm_from_network(container_id, container_ip, tap_device)
    cleanup(container_id)
  end

  def cleanup(container_id) do
    System.cmd("pkill", ["-f", "firecracker.*api.sock"], stderr_to_stdout: true)
    File.rm_rf(Path.join(@vm_dir, container_id))
    Zypi.Container.Console.stop(container_id)
    :ok
  end

  def send_input(container_id, input) do
    Zypi.Container.Console.send_input(container_id, input)
  end

  def mac_for_id(id) do
    <<a, b, c, d, e, _::binary>> = :crypto.hash(:md5, id)
    hex = fn n -> n |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase() end
    "02:#{hex.(a)}:#{hex.(b)}:#{hex.(c)}:#{hex.(d)}:#{hex.(e)}"
  end

  def firecracker_path do
    System.find_executable("firecracker") || "/usr/local/bin/firecracker"
  end

  def safe_close_port(port) when is_port(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end
  def safe_close_port(_), do: :ok
end
