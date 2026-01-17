defmodule Zypi.Image.InitGenerator do
  @moduledoc """
  Generates init scripts and injects guest agent into rootfs images.
  """

  require Logger

  @agent_binary_path "/opt/zypi/bin/zypi-agent"
  @agent_dest_path "/usr/local/bin/zypi-agent"

  @doc """
  Inject init script and agent into an ext4 image.
  """
  def inject(ext4_path, container_config) do
    mount_point = create_temp_mount()

    try do
      with :ok <- mount_image(ext4_path, mount_point),
           :ok <- inject_agent(mount_point),
           :ok <- inject_init_script(mount_point, container_config),
           :ok <- inject_config(mount_point, container_config),
           :ok <- setup_ssh(mount_point) do
        :ok
      end
    after
      unmount_image(mount_point)
      cleanup_temp_mount(mount_point)
    end
  end

  defp create_temp_mount do
    path = "/tmp/zypi-mount-#{System.unique_integer([:positive])}"
    File.mkdir_p!(path)
    path
  end

  defp cleanup_temp_mount(path) do
    File.rmdir(path)
  rescue
    _ -> :ok
  end

  defp mount_image(ext4_path, mount_point) do
    case System.cmd("mount", ["-o", "loop", ext4_path, mount_point], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:mount_failed, code, output}}
    end
  end

  defp unmount_image(mount_point) do
    System.cmd("umount", [mount_point], stderr_to_stdout: true)
  end

  defp inject_agent(mount_point) do
    dest = Path.join(mount_point, @agent_dest_path)
    dir = Path.dirname(dest)

    File.mkdir_p!(dir)

    if File.exists?(@agent_binary_path) do
      Logger.info("InitGenerator: Copying agent from #{@agent_binary_path} to #{dest}")

      case File.cp(@agent_binary_path, dest) do
        :ok ->
          File.chmod!(dest, 0o755)

          # Verify the copy
          case File.stat(dest) do
            {:ok, %{size: size}} ->
              Logger.info("InitGenerator: Agent installed successfully (#{size} bytes)")
              :ok
            {:error, reason} ->
              Logger.error("InitGenerator: Failed to stat agent after copy: #{inspect(reason)}")
              {:error, reason}
          end
        error ->
          Logger.error("InitGenerator: Failed to copy agent: #{inspect(error)}")
          error
      end
    else
      Logger.error("InitGenerator: Guest agent binary not found at #{@agent_binary_path}")
      Logger.error("InitGenerator: VMs will boot but agent won't be available!")
      :ok # Continue anyway but log the error
    end
  end

  defp inject_init_script(mount_point, config) do
    init_script = generate_init_script(config)
    init_path = Path.join(mount_point, "sbin/zypi-init")

    File.mkdir_p!(Path.join(mount_point, "sbin"))
    File.write!(init_path, init_script)
    File.chmod!(init_path, 0o755)

    sbin_init = Path.join(mount_point, "sbin/init")
    File.rm(sbin_init)
    File.ln_s!("zypi-init", sbin_init)

    :ok
  end

  defp inject_config(mount_point, config) do
    config_dir = Path.join(mount_point, "etc/zypi")
    File.mkdir_p!(config_dir)

    config_path = Path.join(config_dir, "config.json")
    File.write!(config_path, Jason.encode!(config, pretty: true))

    :ok
  end

  defp setup_ssh(mount_point) do
    ssh_key_path = Application.get_env(:zypi, :ssh_key_path)

    if ssh_key_path && File.exists?("#{ssh_key_path}.pub") do
      ssh_dir = Path.join(mount_point, "root/.ssh")
      File.mkdir_p!(ssh_dir)
      File.chmod!(ssh_dir, 0o700)

      pub_key = File.read!("#{ssh_key_path}.pub")
      auth_keys = Path.join(ssh_dir, "authorized_keys")
      File.write!(auth_keys, pub_key)
      File.chmod!(auth_keys, 0o600)
    end

    :ok
  end

  defp generate_init_script(config) do
    entrypoint = Map.get(config, :entrypoint) || []
    cmd = Map.get(config, :cmd) || []
    env = Map.get(config, :env) || []
    workdir = Map.get(config, :workdir) || "/"

    env_exports = env
    |> Enum.map(&"export #{&1}")
    |> Enum.join("\n")

    main_cmd = case {entrypoint, cmd} do
      {[], []} -> nil
      {[], c} -> shell_escape(c)
      {e, []} -> shell_escape(e)
      {e, c} -> shell_escape(e ++ c)
    end

    entrypoint_section = if main_cmd do
      """
      cd #{workdir}
      (#{main_cmd}) &
      ENTRYPOINT_PID=$!
      """
    else
      "cd #{workdir}"
    end

    """
    #!/bin/sh
    set -e

    mount -t proc proc /proc 2>/dev/null || true
    mount -t sysfs sysfs /sys 2>/dev/null || true
    mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
    mkdir -p /dev/pts /dev/shm /run /var/log
    mount -t devpts devpts /dev/pts 2>/dev/null || true
    mount -t tmpfs tmpfs /run 2>/dev/null || true
    mount -t tmpfs tmpfs /tmp 2>/dev/null || true

    ip link set lo up 2>/dev/null || true
    ip link set eth0 up 2>/dev/null || true
    sleep 0.5

    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export HOME=/root
    export TERM=linux
    #{env_exports}

    if [ -x /usr/local/bin/zypi-agent ]; then
        echo "Starting zypi-agent..."
        /usr/local/bin/zypi-agent &
        AGENT_PID=$!
        echo "Agent started (PID: $AGENT_PID)"
    else
        echo "Warning: zypi-agent not found"
    fi

    if [ -x /usr/sbin/sshd ]; then
        mkdir -p /run/sshd
        [ ! -f /etc/ssh/ssh_host_rsa_key ] && ssh-keygen -A 2>/dev/null
        /usr/sbin/sshd -D -e &
        SSH_PID=$!
        echo "SSH started (PID: $SSH_PID)"
    fi

    #{entrypoint_section}

    touch /run/zypi-ready
    echo "Init complete, VM ready"

    while true; do
        if [ -n "$AGENT_PID" ] && ! kill -0 $AGENT_PID 2>/dev/null; then
            echo "Agent died, shutting down"
            sync
            poweroff -f
        fi
        sleep 5
    done
    """
  end

  defp shell_escape(args) when is_list(args) do
    Enum.map_join(args, " ", &("'" <> String.replace(&1, "'", "'\\''") <> "'"))
  end
end
