defmodule Zypi.Application do
  @moduledoc """
  Zypi distributed container platform.
  """

  use Application
  require Zypi.Telemetry

  @impl true
  def start(_type, _args) do
    Zypi.Telemetry.setup()  # Add this line
    Zypi.System.Stats.init()
    setup_network_bridge()
    detect_and_set_ssh_key_path()

    children = [
      Zypi.Store.Supervisor,
      Zypi.Pool.Supervisor,
      Zypi.Cluster.Supervisor,
      Zypi.Image.Supervisor,
      Zypi.Container.Supervisor,
      Zypi.Scheduler.Supervisor,
      Zypi.API.Supervisor,
      Zypi.API.ConsoleSocket # Add the new ConsoleSocket supervisor
    ]

    opts = [strategy: :one_for_one, name: Zypi.Supervisor]
    Supervisor.start_link(children, opts)
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
