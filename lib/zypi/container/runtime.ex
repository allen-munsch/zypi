defmodule Zypi.Container.Runtime do
  require Logger

  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")
  @bundles_dir Path.join(@data_dir, "bundles")

  def start(container) do
    Logger.info("Starting container #{container.id} with rootfs: #{container.rootfs}")

    # Check if rootfs device exists
    unless File.exists?(container.rootfs) do
      Logger.error("Rootfs device does not exist: #{container.rootfs}")
      {:error, :rootfs_not_found}
    else
      bundle = prepare_bundle(container)
      Logger.debug("Bundle prepared at: #{bundle}")

      # Clean up any existing container first (to avoid "already exists" error)
      force_delete_container(container.id)

      # Use Port to run crun and capture output
      # We run `crun run` without -d so that it runs in the foreground and we capture the output.
      # The port will send the output to the manager and we can store it.
      command = "crun run --bundle #{bundle} #{container.id}"
      port = Port.open({:spawn, command}, [:binary, :exit_status, :stderr_to_stdout])

      {:ok, port}
    end
  end

  defp start_container(container_id) do
    Logger.debug("Starting container #{container_id}")

    # Run crun start in a separate process
    spawn(fn ->
      {output, code} = System.cmd("crun", ["start", container_id],
                                   stderr_to_stdout: true)
      output = String.trim(output)
      Logger.debug("crun start finished: code=#{code}, output=#{output}")
    end)

    # Wait for container to start
    Process.sleep(500)

    # Check if container is now running
    case check_container_status(container_id) do
      {:ok, %{"status" => "running", "pid" => pid}} ->
        Logger.info("Container #{container_id} started with PID: #{pid}")
        {:ok, pid}

      {:ok, %{"status" => "running"}} ->
        Logger.info("Container #{container_id} is running")
        {:ok, container_id}

      {:ok, state} ->
        Logger.error("Container in unexpected state after start: #{inspect(state)}")
        {:error, :start_failed}

      error ->
        Logger.error("Failed to start container: #{inspect(error)}")
        {:error, :start_failed}
    end
  end

  defp check_container_status(container_id) do
    case System.cmd("crun", ["state", container_id], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, Jason.decode!(output)}
      {error, _} ->
        error = String.trim(error)
        if String.contains?(error, "does not exist") or
           String.contains?(error, "No such file") do
          {:error, :not_found}
        else
          {:error, error}
        end
    end
  end

  defp force_delete_container(container_id) do
    Logger.debug("Force deleting container #{container_id}")

    # Kill any running crun process for this container
    System.cmd("pkill", ["-f", "crun.*#{container_id}"], stderr_to_stdout: true)

    # Delete the container if it exists
    System.cmd("crun", ["delete", "-f", container_id], stderr_to_stdout: true)

    # Remove cgroup directory
    cgroup_path = "/sys/fs/cgroup/#{container_id}"
    System.cmd("rmdir", [cgroup_path], stderr_to_stdout: true)

    Process.sleep(100)
  end

  defp prepare_bundle(container) do
    bundle = Path.join(@bundles_dir, container.id)

    # Clean up any existing bundle
    cleanup_rootfs(container.id)

    # Create fresh bundle directory
    File.mkdir_p!(bundle)
    rootfs_path = Path.join(bundle, "rootfs")
    File.mkdir_p!(rootfs_path)

    Logger.debug("Created bundle directory: #{bundle}")

    # Mount the thin device
    Logger.debug("Mounting thin device: #{container.rootfs} to #{rootfs_path}")
    case System.cmd("mount", ["-t", "ext4", container.rootfs, rootfs_path], stderr_to_stdout: true) do
      {output, 0} ->
        Logger.debug("Mounted successfully: #{String.trim(output)}")
      {error, code} ->
        error = String.trim(error)
        Logger.error("Mount failed: #{error}, code: #{code}")
        raise "Failed to mount thin device"
    end

    # Create OCI config - SIMPLIFIED based on your working manual test
    config = %{
      ociVersion: "1.0.0",
      process: %{
        terminal: false,
        user: %{uid: 0, gid: 0},
        args: ["/hello.sh"],
        env: ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
        cwd: "/",
        noNewPrivileges: false  # Alpine might need privileges for some operations
      },
      root: %{
        path: "rootfs",
        readonly: true
      },
      hostname: container.id,
      linux: %{
        namespaces: [
          %{type: "pid"},
          %{type: "mount"},
          %{type: "ipc"},
          %{type: "uts"},
          %{type: "network"}
        ],
        cgroupsPath: "/#{container.id}",
        resources: %{
          memory: %{
            limit: 268435456,
            reservation: 134217728
          }
        }
      },
      mounts: [
        %{destination: "/proc", type: "proc", source: "proc"},
        %{destination: "/dev", type: "tmpfs", source: "tmpfs", options: ["nosuid", "strictatime", "mode=755", "size=65536k"]},
        %{destination: "/dev/pts", type: "devpts", source: "devpts", options: ["nosuid", "noexec", "newinstance", "ptmxmode=0666", "mode=0620"]},
        %{destination: "/dev/shm", type: "tmpfs", source: "shm", options: ["nosuid", "noexec", "nodev", "mode=1777", "size=65536k"]},
        %{destination: "/sys", type: "sysfs", source: "sysfs", options: ["nosuid", "noexec", "nodev", "ro"]}
      ]
    }

    config_json = Jason.encode!(config, pretty: true)
    config_path = Path.join(bundle, "config.json")
    File.write!(config_path, config_json)
    Logger.debug("Created config at: #{config_path}")

    bundle
  end

  def stop(%{id: id}) do
    Logger.info("Stopping container #{id}")

    # Kill the container process
    System.cmd("crun", ["kill", id, "SIGTERM"], stderr_to_stdout: true)
    Process.sleep(200)
    System.cmd("crun", ["kill", id, "SIGKILL"], stderr_to_stdout: true)

    # Delete the container
    System.cmd("crun", ["delete", "-f", id], stderr_to_stdout: true)

    :ok
  end

  def exec(container_id, cmd \\ ["/bin/sh"]) do
    System.cmd("crun", ["exec", "-t", container_id | cmd])
  end

  def cleanup_rootfs(container_id) do
    bundle = Path.join(@bundles_dir, container_id)
    rootfs = Path.join(bundle, "rootfs")

    Logger.debug("Cleaning up rootfs for #{container_id}")

    # Unmount if mounted
    try do
      System.cmd("umount", [rootfs], stderr_to_stdout: true)
    rescue
      _ -> :ok
    end

    # Clean up bundle directory
    File.rm_rf(bundle)

    :ok
  end
end
