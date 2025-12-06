defmodule Zypi.Container.RuntimeFirecracker do
  @moduledoc """
  Firecracker microVM runtime for Zypi containers.
  """
  require Logger
  alias Zypi.Container.Console

  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")
  @vm_dir Path.join( @data_dir, "vms")
  @kernel_path Application.compile_env(:zypi, :kernel_path, "/opt/zypi/kernel/vmlinux")
  @initrd_path Application.compile_env(:zypi, :initrd_path, "/opt/zypi/kernel/initramfs.img")
  # @initrd_path Application.compile_env(:zypi, :initrd_path, "/opt/zypi/kernel/ubuntu-initrd.img")
  # @initrd_path Application.compile_env(:zypi, :initrd_path, "/opt/zypi/kernel/alpine-initrd.img")

  defmodule VMState do
    defstruct [:socket_path, :fc_port, :tap_device]
  end

  def start(container) do
    Logger.info("Starting Firecracker VM for #{container.id}")

    vm_path = Path.join( @vm_dir, container.id)
    File.mkdir_p!(vm_path)
    socket_path = Path.join(vm_path, "api.sock")
    File.rm(socket_path)


    with {:ok, tap} <- setup_tap(container.id, container.ip),
         {:ok, fc_port} <- spawn_firecracker(socket_path),
         :ok <- wait_for_socket(socket_path),
         :ok <- configure_vm(socket_path, container, tap),
         :ok <- start_instance(socket_path) do

          {:ok, _console_pid} = Zypi.Container.Console.start_link(container.id, fc_port)
          
          # NOTE: Port data is received by Manager (port owner) and forwarded to Console
          # The monitor_vm spawn was removed as it never received port messages
      
          {:ok, %VMState{
            socket_path: socket_path,
            fc_port: fc_port,
            tap_device: tap
          }}    else
      {:error, reason} = err ->
        Logger.error("VM start failed for #{container.id}: #{inspect(reason)}")
        cleanup(container.id)
        err
    end
  end

  def stop(%{id: id, pid: %VMState{} = state}) do
    Logger.info("Stopping VM #{id}")
    api_request(state.socket_path, :put, "/actions", %{action_type: "SendCtrlAltDel"})
    Process.sleep(500)
    safe_close_port(state.fc_port)
    cleanup(id)
    :ok
  end
  def stop(%{id: id}), do: cleanup(id)

  def cleanup_rootfs(container_id), do: cleanup(container_id)

  defp spawn_firecracker(socket_path) do
    port = Port.open({:spawn_executable, firecracker_path()}, [
      :binary,
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
    # rootfs_path = container.rootfs

    rootfs_path = "/opt/zypi/rootfs/ubuntu-24.04.ext4"
    Logger.info("Container rootfs from struct: #{rootfs_path}")
    Logger.info("File.exists?(rootfs_path): #{File.exists?(rootfs_path)}")

    # Check if it's a block device or regular file
    case System.cmd("file", [rootfs_path], stderr_to_stdout: true) do
      {output, _} -> Logger.info("File type: #{String.trim(output)}")
    end

    # Check if it's a device
    case System.cmd("ls", ["-la", rootfs_path], stderr_to_stdout: true) do
      {output, _} -> Logger.info("ls -la: #{String.trim(output)}")
    end

    # For now, bypass dm-snapshot and use the base image directly
    image_id = Base.url_encode64(container.image, padding: false)
    data_dir = Application.get_env(:zypi, :data_dir, "/var/lib/zypi")
    base_image = Path.join([data_dir, "devices", "#{image_id}.img"])

    Logger.info("Base image path: #{base_image}")
    Logger.info("Base image exists?: #{File.exists?(base_image)}")

    # USE THE BASE IMAGE DIRECTLY FOR NOW (bypass dm-snapshot)
    rootfs_path = base_image

    Logger.info("Using kernel: #{@kernel_path}")
    Logger.info("Using rootfs_path: #{rootfs_path}")
    Logger.info("Using initrd: #{@initrd_path}")

    # Verify files exist
    if not File.exists?(@kernel_path) do
      Logger.error("Kernel not found at #{@kernel_path}")
    end

    if not File.exists?(@initrd_path) do
      Logger.error("Initrd not found at #{@initrd_path}")
    end

    vm_path = Path.join(@vm_dir, container.id)
    serial_path = Path.join(vm_path, "serial.log")
    # Create serial log file
    File.write!(serial_path, "")


    mem_mb = get_in(container.resources, [:memory_mb]) || 128
    vcpus = get_in(container.resources, [:cpu]) || 1
    {a, b, c, d} = container.ip
    ip_str = "#{a}.#{b}.#{c}.#{d}"
    gateway = "#{a}.#{b}.#{c}.1"

    # boot_args = [
    #   "console=ttyS0",  # Serial console
    #   "reboot=k",
    #   "panic=1",
    #   "pci=off",
    #   # "root=/dev/ram0",
    #   "root=/dev/vda",
    #   # "root=LABEL=writable",
    #   # "rootfstype=ext4",
    #   # "root=",
    #   "rw",
    #   # "init=/bin/busybox init",
    #   # "init=/bin/busybox init",  # Run BusyBox's init function
    #   # "init=/bin/busybox sh",
    #   # "init=/bin/busybox",  # Direct BusyBox init"
    #   # "init=/bin/sh -c 'mount -t devpts devpts /dev/pts && exec /bin/sh'",
    #   # "init=/bin/sh",  # Bypass init entirely
    #   # "init=/sbin/init init",  # This points to busybox
    #   # "init=/sbin/init",  # Use this instead of rdinit if using full rootfs
    #   # "rdinit=/sbin/init",  # try using initrd
    #   "rdinit=/init",  # The initrd's init program is typically /init or /sbin/init
    #   # "debug",
    #   # "earlyprintk",
    #   # "ignore_loglevel",
    #   # "initcall_debug",
    #   # Add these for better compatibility
    #   # "modules=loop,squashfs",
    #   # "alpine_dev=eth0:dhcp",
    #   "ip=#{ip_str}::#{gateway}:255.255.255.0::eth0:off"
    # ] |> Enum.join(" ")

    # with :ok <- api_request(socket_path, :put, "/boot-source", %{
    #       kernel_image_path: @kernel_path,
    #       # Add the initrd_path here:
    #       # initrd_path: @initrd_path,
    #       initrd_path: nil,
    #       boot_args: boot_args
    #     }),

    # boot_args = [
    #   "console=ttyS0",
    #   "reboot=k",
    #   "panic=1",
    #   "pci=off",
    #   "root=/dev/vda",
    #   "rw",
    #   "ip=#{ip_str}::#{gateway}:255.255.255.0::eth0:off"
    # ] |> Enum.join(" ")

    # boot_args = "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw init=/init.sh"

    boot_args = [
      "console=ttyS0",
      "reboot=k",
      "panic=1",
      "pci=off",
      "root=/dev/vda",
      "rw",
      "init=/sbin/init",
      # "init=/bin/sh",  # Changed from /sbin/init
      "ip=#{ip_str}::#{gateway}:255.255.255.0::eth0:off"
    ] |> Enum.join(" ")

    with :ok <- api_request(socket_path, :put, "/boot-source", %{
          kernel_image_path: @kernel_path,
          # No initrd_path needed - kernel has virtio built-in
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

  defp setup_tap(container_id, ip) do
    tap_name = "ztap#{:erlang.phash2(container_id, 9999)}"
    bridge_name = "zypi0"
    
    # Create TAP device
    System.cmd("ip", ["tuntap", "add", tap_name, "mode", "tap"], stderr_to_stdout: true)
    System.cmd("ip", ["link", "set", tap_name, "up"], stderr_to_stdout: true)
    
    # Add TAP to bridge
    System.cmd("ip", ["link", "set", tap_name, "master", bridge_name], stderr_to_stdout: true)
    
    # IP forwarding (ensure it's enabled)
    System.cmd("sysctl", ["-w", "net.ipv4.ip_forward=1"], stderr_to_stdout: true)

    {:ok, tap_name}
  end

  defp cleanup(container_id) do
    tap_name = "ztap#{:erlang.phash2(container_id, 9999)}"
    System.cmd("ip", ["link", "del", tap_name], stderr_to_stdout: true)
    System.cmd("pkill", ["-f", "firecracker.*api.sock"], stderr_to_stdout: true)
    File.rm_rf(Path.join( @vm_dir, container_id))
  # FIXED: Use the correct API to stop console
  Zypi.Container.Console.stop(container_id)
    :ok
  end



  def send_input(container_id, input) do
    Zypi.Container.Console.send_input(container_id, input)
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
