defmodule Zypi.Application do
  @moduledoc """
  Zypi distributed container platform.
  """

  use Application

  @impl true
  def start(_type, _args) do
    Zypi.System.Stats.init()
    
    # Detect SSH key path from available rootfs images
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
