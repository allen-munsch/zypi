defmodule Zypi.Runtime.Firecracker do
  @moduledoc """
  Firecracker microVM runtime for Linux with KVM.
  """

  @behaviour Zypi.Runtime.Behaviour
  require Logger

  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")
  @vm_dir Path.join(@data_dir, "vms")
  @kernel_path Application.compile_env(:zypi, :kernel_path, "/opt/zypi/kernel/vmlinux")

  # Check if Firecracker is available
  @impl true
  def available? do
    cond do
      :os.type() != {:unix, :linux} ->
        false
      not kvm_available?() ->
        Logger.debug("Firecracker: KVM not available")
        false
      not firecracker_installed?() ->
        Logger.debug("Firecracker: binary not found")
        false
      true ->
        true
    end
  end

  @impl true
  def name, do: "Firecracker"

  defp kvm_available? do
    File.exists?("/dev/kvm") and 
    match?({_, 0}, System.cmd("test", ["-r", "/dev/kvm"], stderr_to_stdout: true))
  end

  defp firecracker_installed? do
    System.find_executable("firecracker") != nil
  end

  @impl true
  def start(container) do
    Logger.info("Firecracker: Starting VM for #{container.id}")

    vm_path = Path.join(@vm_dir, container.id)
    File.mkdir_p!(vm_path)
    socket_path = Path.join(vm_path, "api.sock")
    File.rm(socket_path)

    tap_name = "ztap#{:erlang.phash2(container.id, 9999)}"

    with {:ok, tap} <- setup_tap(container.id, container.ip),
         {:ok, fc_port} <- spawn_firecracker(socket_path),
         :ok <- wait_for_socket(socket_path),
         :ok <- configure_vm(socket_path, container, tap),
         :ok <- start_instance(socket_path) do

      {:ok, %{
        socket_path: socket_path,
        pid: fc_port,
        tap_device: tap,
        container_ip: container.ip
      }}
    else
      {:error, reason} ->
        Logger.error("Firecracker: VM start failed: #{inspect(reason)}")
        cleanup_network(tap_name)
        {:error, reason}
    end
  end

  @impl true
  def stop(%{id: id, pid: vm_state}) when is_map(vm_state) do
    Logger.info("Firecracker: Stopping VM #{id}")

    if vm_state.socket_path do
      try do
        api_request(vm_state.socket_path, :put, "/actions", %{action_type: "SendCtrlAltDel"})
      rescue
        _ -> :ok
      end
    end

    Process.sleep(500)
    safe_close_port(vm_state.pid)

    if vm_state.tap_device do
      teardown_network(id, %{tap_device: vm_state.tap_device, ip: vm_state.container_ip})
    end

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
    socket_path = Path.join(vm_path, "api.sock")
    System.cmd("pkill", ["-f", "firecracker.*#{socket_path}"], stderr_to_stdout: true)
    File.rm_rf(vm_path)
    :ok
  end

  @impl true
  def setup_network(container_id, ip) do
    setup_tap(container_id, ip)
  end

  @impl true
  def teardown_network(container_id, %{tap_device: tap, ip: ip}) do
    cleanup_network_rules(container_id, ip, tap)
    :ok
  end

  def teardown_network(_container_id, _), do: :ok

  # Private implementation functions (same as before)

  defp setup_tap(container_id, _ip) do
    setup_bridge()
    tap_name = "ztap#{:erlang.phash2(container_id, 9999)}"
    bridge_name = "zypi0"

    System.cmd("ip", ["tuntap", "add", tap_name, "mode", "tap"], stderr_to_stdout: true)
    System.cmd("ip", ["link", "set", tap_name, "up"], stderr_to_stdout: true)
    System.cmd("ip", ["link", "set", tap_name, "promisc", "on"], stderr_to_stdout: true)
    System.cmd("ip", ["link", "set", tap_name, "master", bridge_name], stderr_to_stdout: true)
    System.cmd("sysctl", ["-w", "net.ipv4.ip_forward=1"], stderr_to_stdout: true)

    {:ok, tap_name}
  end

  defp setup_bridge do
    case System.cmd("ip", ["link", "show", "zypi0"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ ->
        System.cmd("ip", ["link", "add", "name", "zypi0", "type", "bridge"])
        System.cmd("ip", ["addr", "add", "10.0.0.1/24", "dev", "zypi0"])
        System.cmd("ip", ["link", "set", "zypi0", "up"])
        System.cmd("iptables", ["-A", "FORWARD", "-i", "zypi0", "-j", "ACCEPT"])
        System.cmd("iptables", ["-A", "FORWARD", "-o", "zypi0", "-j", "ACCEPT"])
    end
    :ok
  end

  defp cleanup_network(tap_name) do
    System.cmd("ip", ["link", "del", tap_name], stderr_to_stdout: true)
  end

  defp cleanup_network_rules(_container_id, ip, tap) do
    {a, b, c, d} = ip
    ip_str = "#{a}.#{b}.#{c}.#{d}"

    System.cmd("iptables", ["-t", "nat", "-D", "POSTROUTING", "-s", "#{ip_str}/24", "-j", "MASQUERADE"], stderr_to_stdout: true)
    System.cmd("ip", ["link", "del", tap], stderr_to_stdout: true)
  end

  defp spawn_firecracker(socket_path) do
    port = Port.open({:spawn_executable, firecracker_path()},
      [:binary,
       :exit_status,
       :stderr_to_stdout,
       args: ["--api-sock", socket_path]
      ])
    Process.sleep(100)
    {:ok, port}
  end

  defp wait_for_socket(path, attempts \\ 100) do
    cond do
      File.exists?(path) -> :ok
      attempts <= 0 -> {:error, :socket_timeout}
      true -> Process.sleep(10); wait_for_socket(path, attempts - 1)
    end
  end

  defp configure_vm(socket_path, container, tap) do
    rootfs_path = container.rootfs
    mem_mb = get_in(container.resources, [:memory_mb]) || 256
    vcpus = get_in(container.resources, [:cpu]) || 1
    {a, b, c, d} = container.ip
    ip_str = "#{a}.#{b}.#{c}.#{d}"
    gateway = "#{a}.#{b}.#{c}.1"

    boot_args = [
      "console=ttyS0", "reboot=k", "panic=1", "pci=off",
      "root=/dev/vda", "rw", "init=/sbin/init",
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
        :ok <- api_request(socket_path, :put, "/network-interfaces/eth0", %{
          iface_id: "eth0",
          host_dev_name: tap,
          guest_mac: mac_for_id(container.id)
        }) do
      :ok
    end
  end

  defp start_instance(socket_path) do
    api_request(socket_path, :put, "/actions", %{action_type: "InstanceStart"})
  end

  defp api_request(socket_path, method, path, body) do
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
            if response =~ ~r/HTTP\/1\.[01] (200|204)/, do: :ok, else: {:error, {:http_error, response}}
          {:error, reason} -> {:error, {:recv_error, reason}}
        end
        :gen_tcp.close(socket)
        result
      {:error, reason} -> {:error, {:connect_error, reason}}
    end
  end

  defp mac_for_id(id) do
    <<a, b, c, d, e, _::binary>> = :crypto.hash(:md5, id)
    hex = fn n -> n |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase() end
    "02:#{hex.(a)}:#{hex.(b)}:#{hex.(c)}:#{hex.(d)}:#{hex.(e)}"
  end

  defp firecracker_path do
    System.find_executable("firecracker") || "/usr/local/bin/firecracker"
  end

  defp safe_close_port(port) when is_port(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end
  defp safe_close_port(_), do: :ok
end