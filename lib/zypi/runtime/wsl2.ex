defmodule Zypi.Runtime.WSL2 do
  @moduledoc """
  WSL2 runtime for Windows - runs Firecracker inside WSL2.
  
  This provides near-native Firecracker performance on Windows by
  using the actual Linux kernel in WSL2 with nested virtualization.
  
  Requirements:
  - Windows 10 2004+ or Windows 11
  - WSL2 with a Linux distro installed
  - Nested virtualization enabled in WSL2
  - Firecracker installed in WSL2
  """

  @behaviour Zypi.Runtime.Behaviour
  require Logger

  @wsl_distro Application.compile_env(:zypi, :wsl_distro, "Ubuntu")
  @data_dir "/var/lib/zypi"  # Path inside WSL

  @impl true
  def available? do
    cond do
      :os.type() != {:win32, :nt} ->
        false
      not wsl2_available?() ->
        Logger.debug("WSL2: WSL2 not available")
        false
      not firecracker_in_wsl?() ->
        Logger.debug("WSL2: Firecracker not installed in WSL")
        false
      true ->
        true
    end
  end

  @impl true
  def name, do: "WSL2+Firecracker"

  defp wsl2_available? do
    case System.cmd("wsl", ["--status"], stderr_to_stdout: true) do
      {output, 0} -> String.contains?(output, "2")
      _ -> false
    end
  end

  defp firecracker_in_wsl? do
    case wsl_cmd(["which", "firecracker"]) do
      {_, 0} -> true
      _ -> false
    end
  end

  @impl true
  def start(container) do
    Logger.info("WSL2: Starting VM for #{container.id}")

    # Convert Windows path to WSL path for rootfs
    wsl_rootfs = windows_to_wsl_path(container.rootfs)
    
    # Create VM directory in WSL
    wsl_cmd(["mkdir", "-p", "#{@data_dir}/vms/#{container.id}"])

    # Copy rootfs to WSL if needed
    if not String.starts_with?(container.rootfs, "/") do
      wsl_cmd(["cp", wsl_rootfs, "#{@data_dir}/vms/#{container.id}/rootfs.ext4"])
      wsl_rootfs = "#{@data_dir}/vms/#{container.id}/rootfs.ext4"
    end

    socket_path = "#{@data_dir}/vms/#{container.id}/api.sock"
    
    # Build Firecracker command to run in WSL
    mem_mb = get_in(container.resources, [:memory_mb]) || 256
    cpus = get_in(container.resources, [:cpu]) || 1
    {a, b, c, d} = container.ip
    ip_str = "#{a}.#{b}.#{c}.#{d}"

    # Start Firecracker in WSL (backgrounded)
    fc_script = """
    #!/bin/bash
    set -e
    cd #{@data_dir}/vms/#{container.id}
    
    # Start Firecracker
    firecracker --api-sock #{socket_path} &
    FC_PID=$!
    sleep 1
    
    # Configure VM via API
    curl -s --unix-socket #{socket_path} -X PUT http://localhost/boot-source \
      -H 'Content-Type: application/json' \
      -d '{"kernel_image_path": "/opt/zypi/kernel/vmlinux", "boot_args": "console=ttyS0 root=/dev/vda rw init=/sbin/init ip=#{ip_str}::10.0.0.1:255.255.255.0::eth0:off"}'
    
    curl -s --unix-socket #{socket_path} -X PUT http://localhost/machine-config \
      -H 'Content-Type: application/json' \
      -d '{"vcpu_count": #{cpus}, "mem_size_mib": #{mem_mb}}'
    
    curl -s --unix-socket #{socket_path} -X PUT http://localhost/drives/rootfs \
      -H 'Content-Type: application/json' \
      -d '{"drive_id": "rootfs", "path_on_host": "#{wsl_rootfs}", "is_root_device": true, "is_read_only": false}'
    
    curl -s --unix-socket #{socket_path} -X PUT http://localhost/actions \
      -H 'Content-Type: application/json' \
      -d '{"action_type": "InstanceStart"}'
    
    echo $FC_PID > pid
    wait $FC_PID
    """

    script_path = "#{@data_dir}/vms/#{container.id}/start.sh"
    wsl_cmd(["bash", "-c", "cat > #{script_path} << 'EOF'\n#{fc_script}\nEOF"])
    wsl_cmd(["chmod", "+x", script_path])

    # Run the script in background
    Task.start(fn ->
      wsl_cmd(["bash", script_path])
    end)

    # Wait for socket
    case wait_for_socket_wsl(socket_path) do
      :ok ->
        {:ok, %{
          socket_path: socket_path,
          pid: nil,
          container_ip: container.ip,
          wsl_distro: @wsl_distro
        }}
      error -> error
    end
  end

  @impl true
  def stop(%{id: id, pid: _vm_state}) do
    Logger.info("WSL2: Stopping VM #{id}")

    # Kill Firecracker in WSL
    wsl_cmd(["pkill", "-f", "firecracker.*#{id}"])
    
    cleanup(id)
    :ok
  end

  def stop(%{id: id}), do: cleanup(id)

  @impl true
  def exec(container_id, cmd, opts) do
    # Execute via agent - need to proxy through WSL
    # The agent is running inside the Firecracker VM inside WSL
    Zypi.Container.Agent.exec(container_id, cmd, opts)
  end

  @impl true
  def health(container_id) do
    Zypi.Container.Agent.health(container_id)
  end

  @impl true
  def cleanup(container_id) do
    wsl_cmd(["rm", "-rf", "#{@data_dir}/vms/#{container_id}"])
    :ok
  end

  @impl true
  def setup_network(container_id, ip) do
    # WSL2 networking - use bridge in WSL
    wsl_cmd(["bash", "-c", """
    ip link add zypi0 type bridge 2>/dev/null || true
    ip addr add 10.0.0.1/24 dev zypi0 2>/dev/null || true
    ip link set zypi0 up
    echo 1 > /proc/sys/net/ipv4/ip_forward
    iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -j MASQUERADE 2>/dev/null || true
    """])
    
    {:ok, %{mode: :wsl_bridge, container_id: container_id, ip: ip}}
  end

  @impl true
  def teardown_network(_container_id, _state) do
    :ok
  end

  # Private functions

  defp wsl_cmd(args) do
    System.cmd("wsl", ["-d", @wsl_distro, "--"] ++ args, stderr_to_stdout: true)
  end

  defp windows_to_wsl_path(path) do
    # Convert C:\path\to\file to /mnt/c/path/to/file
    path
    |> String.replace("\\", "/")
    |> String.replace(~r/^([A-Za-z]):/, fn _, drive -> "/mnt/#{String.downcase(drive)}" end)
  end

  defp wait_for_socket_wsl(socket_path, attempts \\ 50) do
    {output, _} = wsl_cmd(["test", "-S", socket_path])
    cond do
      output == "" -> :ok
      attempts <= 0 -> {:error, :socket_timeout}
      true ->
        Process.sleep(100)
        wait_for_socket_wsl(socket_path, attempts - 1)
    end
  end
end
