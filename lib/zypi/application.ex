defmodule Zypi.Application do
  @moduledoc """
  Zypi distributed container platform.
  """

  use Application
  require Zypi.Telemetry

  @impl true
  def start(_type, _args) do
    Zypi.Telemetry.setup() # Add this line
    Zypi.System.Stats.init()

    validate_prerequisites() # Add this line

    setup_network_bridge()
    detect_and_set_ssh_key_path()

    children = [
      Zypi.Store.Supervisor,
      Zypi.Pool.Supervisor,
      Zypi.Cluster.Supervisor,
      Zypi.Image.Supervisor,
      Zypi.Container.Supervisor,
      Zypi.Scheduler.Supervisor,
      Zypi.System.Cleanup,
      Zypi.API.Supervisor,
      Zypi.API.ConsoleSocket
    ]

    opts = [strategy: :one_for_one, name: Zypi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp validate_prerequisites do
    require Logger
    Logger.info("Validating Zypi prerequisites...")

    errors = []

    # Check KVM
    errors =
      if File.exists?("/dev/kvm") do
        errors
      else
        ["KVM not available - /dev/kvm does not exist" | errors]
      end

    # Check firecracker binary
    fc_path = System.find_executable("firecracker")

    errors =
      if fc_path do
        Logger.info("Firecracker found at: #{fc_path}")
        errors
      else
        ["Firecracker binary not found in PATH" | errors]
      end

    # Check kernel
    kernel_path = Application.get_env(:zypi, :kernel_path, "/opt/zypi/kernel/vmlinux")

    errors =
      if File.exists?(kernel_path) do
        Logger.info("Kernel found at: #{kernel_path}")
        errors
      else
        ["Kernel not found at: #{kernel_path}" | errors]
      end

    # Check base rootfs
    rootfs_path = "/opt/zypi/rootfs/ubuntu-24.04.ext4"

    errors =
      if File.exists?(rootfs_path) do
        size = File.stat!(rootfs_path).size
        Logger.info("Base rootfs found at: #{rootfs_path} (#{div(size, 1_048_576)} MB)")
        errors
      else
        ["Base rootfs not found at: #{rootfs_path}" | errors]
      end

    # Check zypi-agent binary on host
    agent_path = "/opt/zypi/bin/zypi-agent"

    errors =
      if File.exists?(agent_path) do
        Logger.info("zypi-agent binary found at: #{agent_path}")
        errors
      else
        ["zypi-agent binary not found at: #{agent_path}" | errors]
      end

    # Report results
    if errors == [] do
      Logger.info("All prerequisites validated successfully")
      ensure_base_rootfs_ready()
    else
      Enum.each(Enum.reverse(errors), &Logger.error("PREREQ FAILED: #{&1}"))
      Logger.error("Some prerequisites are missing. VM pool will likely fail.")
    end

    :ok
  end

  defp ensure_base_rootfs_ready do
    require Logger
    base_rootfs = "/opt/zypi/rootfs/ubuntu-24.04.ext4"

    if File.exists?(base_rootfs) do
      Logger.info("Preparing base rootfs with agent and init script...")

      config = %{
        entrypoint: [],
        cmd: [],
        env: [],
        workdir: "/"
      }

      case Zypi.Image.InitGenerator.inject(base_rootfs, config) do
        :ok ->
          Logger.info("Base rootfs prepared successfully")
        {:error, reason} ->
          Logger.error("Failed to prepare base rootfs: #{inspect(reason)}")
      end
    else
      Logger.warning("Base rootfs not found, skipping agent injection")
    end
  end

  defp setup_network_bridge do
    bridge_name = "zypi0"
    gateway_ip = "10.0.0.1"
    
    # Create bridge if it doesn't exist
    case System.cmd("ip", ["link", "show", bridge_name], stderr_to_stdout: true) do
      {_, 0} ->
        # Bridge exists
        :ok
      _ ->
        # Create bridge
        System.cmd("ip", ["link", "add", bridge_name, "type", "bridge"])
        System.cmd("ip", ["addr", "add", "#{gateway_ip}/24", "dev", bridge_name])
        System.cmd("ip", ["link", "set", bridge_name, "up"])
        
        # Enable IP forwarding
        System.cmd("sysctl", ["-w", "net.ipv4.ip_forward=1"])
        
        # Setup NAT
        System.cmd("iptables", ["-t", "nat", "-A", "POSTROUTING", "-s", "10.0.0.0/24", "-j", "MASQUERADE"])
    end
    
    require Logger
    Logger.info("Network bridge #{bridge_name} configured")
  end

  defp detect_and_set_ssh_key_path do
    rootfs_dir = "/opt/zypi/rootfs"
    
    case File.ls(rootfs_dir) do
      {:ok, files} ->
        # Find the SSH key file (e.g., ubuntu-24.04.id_rsa)
        key_file = Enum.find(files, fn f -> 
          String.ends_with?(f, ".id_rsa") 
        end)
        
        if key_file do
          key_path = Path.join(rootfs_dir, key_file)
          Application.put_env(:zypi, :ssh_key_path, key_path)
          require Logger
          Logger.info("SSH key configured: #{key_path}")
        end
        
      {:error, _} ->
        require Logger
        Logger.warning("Could not read rootfs directory for SSH key detection")
    end
  end
end
