defmodule Zypi.Image.BaseRootfs do
  @moduledoc """
  Builds a customized base rootfs with an injected OCI config.
  """
  require Logger

  @base_rootfs_dir "/opt/zypi/rootfs"

  def build_base_with_oci_config(container_config) do
    base_rootfs_path = find_base_rootfs()
    temp_dir = "/tmp/rootfs-build-#{System.unique_integer([:positive])}"
    temp_rootfs = Path.join(temp_dir, "rootfs")
    mount_point = Path.join(temp_dir, "mnt")

    File.mkdir_p!(temp_rootfs)
    File.mkdir_p!(mount_point)

    try do
      # Copy base rootfs content
      copy_base_rootfs(base_rootfs_path, temp_rootfs)

      # Inject init script and config
      inject_vm_init(temp_rootfs, container_config)
      
      # Create an ext4 image from the customized rootfs
      output_image_path = Path.join(temp_dir, "custom_rootfs.ext4")
      create_ext4_image(temp_rootfs, output_image_path)

      {:ok, output_image_path}
    after
      File.rm_rf!(temp_dir)
    end
  end

  defp find_base_rootfs do
    case File.ls(@base_rootfs_dir) do
      {:ok, files} ->
        ext4_file = Enum.find(files, &String.ends_with?(&1, ".ext4"))
        if ext4_file, do: Path.join(@base_rootfs_dir, ext4_file), else: raise "No .ext4 base rootfs found in #{@base_rootfs_dir}"
      {:error, reason} ->
        raise "Cannot read #{@base_rootfs_dir}: #{inspect(reason)}"
    end
  end

  defp copy_base_rootfs(base_path, dest_dir) do
    temp_mount = "/tmp/mnt-#{System.unique_integer([:positive])}"
    File.mkdir_p!(temp_mount)
    
    {:ok, loop_dev} = losetup(base_path)
    
    case System.cmd("mount", ["-o", "ro", loop_dev, temp_mount]) do
      {_, 0} ->
        System.cmd("cp", ["-a", "#{temp_mount}/.", dest_dir])
        System.cmd("umount", [temp_mount])
        System.cmd("losetup", ["-d", loop_dev])
        File.rm_rf!(temp_mount)
        :ok
      {err, code} ->
        System.cmd("losetup", ["-d", loop_dev])
        File.rm_rf!(temp_mount)
        raise "mount failed: #{code}, #{err}"
    end
  end

  defp create_ext4_image(source_dir, image_path) do
    # Calculate size and add some buffer
    {out, 0} = System.cmd("du", ["-sh", source_dir])
    [size | _] = String.split(out)
    # A bit of a hack to get a numeric value in MB
    size_mb = String.to_integer(String.replace(size, "M", "")) + 100

    System.cmd("truncate", ["-s", "#{size_mb}M", image_path])
    System.cmd("mkfs.ext4", ["-F", "-d", source_dir, image_path])
  end
  
  defp inject_vm_init(rootfs_dir, config) do
    ~w[dev proc sys tmp run etc var/run sbin etc/ssh etc/zypi]
    |> Enum.each(&File.mkdir_p!(Path.join(rootfs_dir, &1)))

    File.write!(Path.join(rootfs_dir, "etc/zypi/config.json"), Jason.encode!(config))

    inject_ssh_keys(rootfs_dir)

    init_script = generate_init_script(config)
    init_path = Path.join(rootfs_dir, "sbin/zypi-init")
    File.write!(init_path, init_script)
    File.chmod!(init_path, 0o755)

    sbin_init = Path.join(rootfs_dir, "sbin/init")
    File.rm(sbin_init)
    File.ln_s!("zypi-init", sbin_init)

    :ok
  end

  defp inject_ssh_keys(rootfs_dir) do
    # This logic is copied from the old DevicePool. It finds a public key and injects it.
    # A proper implementation would get the key from a config or API call.
    ssh_key_path = Application.get_env(:zypi, :ssh_key_path)

    public_key = if ssh_key_path && File.exists?("#{ssh_key_path}.pub") do
      File.read!("#{ssh_key_path}.pub")
    else
      # Fallback to a default key if one exists
      default_key = Path.expand("~/.ssh/id_rsa.pub")
      if File.exists?(default_key), do: File.read!(default_key), else: nil
    end

    if public_key do
      authorized_keys_path = Path.join(rootfs_dir, "etc/zypi/authorized_keys")
      File.mkdir_p!(Path.dirname(authorized_keys_path))
      File.write!(authorized_keys_path, public_key)
      File.chmod(authorized_keys_path, 0o600)
    end
  end

  defp generate_init_script(config) do
    entrypoint = config[:entrypoint] || config["entrypoint"] || []
    cmd = config[:cmd] || config["cmd"] || []
    env = config[:env] || config["env"] || []
    workdir = config[:workdir] || config["workdir"] || "/"

    main_cmd = case {entrypoint, cmd} do
      {[], []} -> nil
      {[], c} -> shell_escape(c)
      {e, []} -> shell_escape(e)
      {e, c} -> shell_escape(e ++ c)
    end

    env_exports = env
      |> Enum.map(&"export #{&1}")
      |> Enum.join("\n")

    main_process_section = if main_cmd do
      """
      # Start main container process in background
      echo "[zypi] Starting main process..."
      cd #{workdir}
      (#{main_cmd}) &
      MAIN_PID=$!
      echo "[zypi] Main process started (PID: $MAIN_PID)"
      """
    else
      "cd #{workdir}"
    end

    """
    #!/bin/sh

    # Zypi Container Init Script
    echo "[zypi] Zypi Container Init Starting"

    # Mount essential filesystems
    mount -t proc proc /proc 2>/dev/null || true
    mount -t sysfs sysfs /sys 2>/dev/null || true
    mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
    mkdir -p /dev/pts /dev/shm
    mount -t devpts devpts /dev/pts 2>/dev/null || true
    mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true
    mount -t tmpfs tmpfs /run 2>/dev/null || true
    mount -t tmpfs tmpfs /tmp 2>/dev/null || true

    mkdir -p /run/sshd /var/run
    hostname zypi-container 2>/dev/null || true
    mkdir -p /var/log
    touch /var/log/lastlog
    
    ip link set lo up 2>/dev/null || true
    ip link set eth0 up 2>/dev/null || true

    # Set environment
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export HOME=/root
    export TERM=linux
    #{env_exports}

    # === SSH Setup ===
    setup_ssh() {
      if [ -x /usr/sbin/sshd ]; then
        echo "[zypi] Setting up SSH..."
        mkdir -p /run/sshd /root/.ssh
        chmod 700 /root/.ssh

        if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
          ssh-keygen -A 2>/dev/null || true
        fi
        if [ -f /etc/zypi/authorized_keys ]; then
          cp /etc/zypi/authorized_keys /root/.ssh/authorized_keys
          chmod 600 /root/.ssh/authorized_keys
        fi
        /usr/sbin/sshd -D -e &
      fi
    }

    setup_ssh

    #{main_process_section}

    echo "[zypi] Container ready"

    # Keep init running
    while true; do sleep 60; done
    """
  end

  defp shell_escape(args) when is_list(args) do
    Enum.map_join(args, " ", &("'" <> String.replace(&1, "'", "'\\''") <> "'"))
  end

  defp losetup(path) do
    case System.cmd("losetup", ["--find", "--show", path]) do
      {output, 0} -> {:ok, String.trim(output)}
      {err, code} -> {:error, {:losetup_failed, code, err}}
    end
  end
end
