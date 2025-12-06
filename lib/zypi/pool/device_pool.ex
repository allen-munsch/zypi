defmodule Zypi.Pool.DevicePool do
  @moduledoc """
  Manages base images. Creates ext4 images from OCI layers.
  """
  use GenServer
  require Logger

  alias Zypi.Image.Delta

  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")
  @devices_dir Path.join(@data_dir, "devices")

  defstruct images: MapSet.new(), pending: MapSet.new()

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def acquire(image_ref), do: GenServer.call(__MODULE__, {:acquire, image_ref}, 30_000)
  def warm(image_ref), do: GenServer.cast(__MODULE__, {:warm, image_ref})
  def status, do: GenServer.call(__MODULE__, :status)

  def image_path(image_ref) do
    image_id = Base.url_encode64(image_ref, padding: false)
    Path.join(@devices_dir, "#{image_id}.img")
  end

  @impl true
  def init(_opts) do
    File.mkdir_p!(@devices_dir)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:acquire, image_ref}, _from, state) do
    path = image_path(image_ref)
    if File.exists?(path) do
      {:reply, {:ok, path}, %{state | images: MapSet.put(state.images, image_ref)}}
    else
      {:reply, {:error, :pool_empty}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{ready: MapSet.to_list(state.images), pending: MapSet.to_list(state.pending)}, state}
  end

  @impl true
  def handle_cast({:warm, image_ref}, state) do
    cond do
      MapSet.member?(state.pending, image_ref) ->
        {:noreply, state}

      File.exists?(image_path(image_ref)) ->
        {:noreply, %{state | images: MapSet.put(state.images, image_ref)}}

      true ->
        state = %{state | pending: MapSet.put(state.pending, image_ref)}
        parent = self()
        Task.start(fn -> do_warm(image_ref, parent) end)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:warmed, image_ref, :ok}, state) do
    Logger.info("DevicePool: Image #{image_ref} ready")
    {:noreply, %{state |
      images: MapSet.put(state.images, image_ref),
      pending: MapSet.delete(state.pending, image_ref)
    }}
  end

  @impl true
  def handle_info({:warmed, image_ref, {:error, reason}}, state) do
    Logger.error("DevicePool: Failed to warm #{image_ref}: #{inspect(reason)}")
    {:noreply, %{state | pending: MapSet.delete(state.pending, image_ref)}}
  end

  # No more ThinPool/SnapshotPool.setup_image_pool call - just create the base image
  defp do_warm(image_ref, parent) do
    result = with {:ok, manifest} <- Delta.get(image_ref),
                  {:ok, _path} <- ensure_base_image(image_ref, manifest) do
      :ok
    end
    send(parent, {:warmed, image_ref, result})
  end

  defp ensure_base_image(image_ref, manifest) do
    path = image_path(image_ref)
    if File.exists?(path), do: {:ok, path}, else: create_base_image(path, manifest)
  end

  defp create_base_image(image_path, manifest) do
    layer_size = manifest.size_bytes || 0
    size_mb = max(64, div(layer_size * 150, 100 * 1024 * 1024) + 32)
    work_dir = Path.join(Path.dirname(image_path), "work_#{:erlang.unique_integer([:positive])}")
    rootfs_dir = Path.join(work_dir, "rootfs")
    mount_point = Path.join(work_dir, "mnt")

    Logger.info("DevicePool: Creating base image (#{size_mb}MB)")

    try do
      File.mkdir_p!(rootfs_dir)
      File.mkdir_p!(mount_point)

      # Extract layers - handle both atom and string keys
      config = manifest.overlaybd_config
      config_map = if is_binary(config), do: Jason.decode!(config), else: config

      # Handle both atom and string keys
      layers_url = config_map[:repoBlobUrl] || config_map["repoBlobUrl"] || ""
      layers_path = String.replace_prefix(layers_url, "file://", "")
      lowers = config_map[:lowers] || config_map["lowers"] || []

      Logger.debug("DevicePool: layers_path=#{layers_path}, lowers count=#{length(lowers)}")

      layers_found = Enum.reduce(lowers, 0, fn layer, count ->
        # Handle both atom and string keys for digest
        digest = layer[:digest] || layer["digest"]
        layer_file = Path.join(layers_path, digest)

        Logger.debug("DevicePool: Looking for layer at #{layer_file}")

        if File.exists?(layer_file) do
          Logger.debug("Extracting layer #{String.slice(to_string(digest), 7, 12)}")
          case System.cmd("tar", ["-xf", layer_file, "-C", rootfs_dir], stderr_to_stdout: true) do
            {_, 0} -> :ok
            {err, _} -> Logger.warning("tar extraction warning: #{err}")
          end
          count + 1
        else
          Logger.warning("Layer file not found: #{layer_file}")
          count
        end
      end)

      Logger.info("DevicePool: Extracted #{layers_found} layers")

      # Inject init
      container_config = manifest.container_config || %{}
      inject_vm_init(rootfs_dir, container_config)

      # Create ext4 image
      with {_, 0} <- System.cmd("truncate", ["-s", "#{size_mb}M", image_path]),
           {_, 0} <- System.cmd("mkfs.ext4", ["-F", "-q", image_path]),
           {:ok, loop} <- losetup(image_path),
           {_, 0} <- System.cmd("mount", [loop, mount_point]),
           :ok <- copy_rootfs(rootfs_dir, mount_point),
           {_, 0} <- System.cmd("umount", [mount_point]),
           {_, 0} <- System.cmd("losetup", ["-d", loop]) do
        Logger.info("DevicePool: Created base image (#{layers_found} layers)")
        {:ok, image_path}
      else
        {err, code} ->
          File.rm(image_path)
          {:error, {:image_creation_failed, code, err}}
        {:error, _} = err ->
          File.rm(image_path)
          err
      end
    after
      File.rm_rf(work_dir)
    end
  end



  defp inject_vm_init(rootfs_dir, config) do
    # Create essential directories
    ~w[dev proc sys tmp run etc var/run sbin]
    |> Enum.each(&File.mkdir_p!(Path.join(rootfs_dir, &1)))

    # Create zypi config directory
    zypi_config_dir = Path.join(rootfs_dir, "etc/zypi")
    File.mkdir_p!(zypi_config_dir)
    
    # Write container config
    File.write!(Path.join(zypi_config_dir, "config.json"), Jason.encode!(config))

    # Inject SSH authorized_keys if we have a key
    inject_ssh_keys(rootfs_dir)

    # Write init script
    init_script = generate_init_script(config)
    init_path = Path.join(rootfs_dir, "sbin/zypi-init")
    File.write!(init_path, init_script)
    File.chmod!(init_path, 0o755)

    # Create symlink for /sbin/init
    sbin_init = Path.join(rootfs_dir, "sbin/init")
    File.rm(sbin_init)
    File.ln_s!("zypi-init", sbin_init)
    
    :ok
  end

  defp inject_ssh_keys(rootfs_dir) do
    # Find SSH public key from the pre-built rootfs
    ssh_key_path = Application.get_env(:zypi, :ssh_key_path)
    
    public_key = cond do
      # Try to read .pub version of the private key
      ssh_key_path && File.exists?("#{ssh_key_path}.pub") ->
        File.read!("#{ssh_key_path}.pub")
      
      # Try to find any .pub key in the rootfs directory
      true ->
        case find_ssh_public_key() do
          {:ok, key} -> key
          :not_found -> nil
        end
    end
    
    if public_key do
      authorized_keys_path = Path.join(rootfs_dir, "etc/zypi/authorized_keys")
      File.write!(authorized_keys_path, public_key)
      File.chmod(authorized_keys_path, 0o600)
      Logger.debug("Injected SSH public key into image")
    else
      Logger.warning("No SSH public key found - shell access may not work")
    end
  end

  defp find_ssh_public_key do
    rootfs_dir = "/opt/zypi/rootfs"
    
    case File.ls(rootfs_dir) do
      {:ok, files} ->
        # Find .id_rsa files and look for their .pub counterparts
        key_file = Enum.find_value(files, fn f ->
          if String.ends_with?(f, ".id_rsa") do
            pub_path = Path.join(rootfs_dir, "#{f}.pub")
            priv_path = Path.join(rootfs_dir, f)
            
            cond do
              File.exists?(pub_path) ->
                File.read!(pub_path)
              File.exists?(priv_path) ->
                # Generate public key from private key
                case System.cmd("ssh-keygen", ["-y", "-f", priv_path], stderr_to_stdout: true) do
                  {pub_key, 0} -> pub_key
                  _ -> nil
                end
              true ->
                nil
            end
          end
        end)
        
        if key_file, do: {:ok, key_file}, else: :not_found
        
      {:error, _} ->
        :not_found
    end
  end

  defp generate_init_script(config) do
    entrypoint = config[:entrypoint] || config["entrypoint"] || []
    cmd = config[:cmd] || config["cmd"] || []
    env = config[:env] || config["env"] || []
    workdir = config[:workdir] || config["workdir"] || "/"

    # Build the main process command
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
      echo "[zypi] Main process PID: $MAIN_PID"
      """
    else
      "cd #{workdir}"
    end

    """
    #!/bin/sh
    
    # Zypi container init script
    # Provides SSH access for `zypi shell`
    
    set -e
    
    echo "[zypi] Initializing container..."
    
    # Mount essential filesystems
    mount -t proc proc /proc 2>/dev/null || true
    mount -t sysfs sysfs /sys 2>/dev/null || true
    mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
    mkdir -p /dev/pts /dev/shm
    mount -t devpts devpts /dev/pts 2>/dev/null || true
    mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true
    mount -t tmpfs tmpfs /run 2>/dev/null || true
    mount -t tmpfs tmpfs /tmp 2>/dev/null || true
    
    # Configure networking
    ip link set lo up 2>/dev/null || true
    ip link set eth0 up 2>/dev/null || true
    
    # Set environment
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export HOME=/root
    export TERM=linux
    #{env_exports}
    
    # === SSH Setup ===
    setup_ssh() {
      echo "[zypi] Setting up SSH..."
      
      # Detect package manager and install openssh if needed
      if ! command -v sshd >/dev/null 2>&1; then
        echo "[zypi] Installing SSH server..."
        
        if command -v apk >/dev/null 2>&1; then
          # Alpine
          apk add --no-cache openssh-server
        elif command -v apt-get >/dev/null 2>&1; then
          # Debian/Ubuntu
          apt-get update -qq >/dev/null 2>&1 || true
          DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
          # Fedora/RHEL
          dnf install -y -q openssh-server >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
          # CentOS/older RHEL
          yum install -y -q openssh-server >/dev/null 2>&1 || true
        fi
      fi
      
      # Configure SSH if sshd is available
      if command -v sshd >/dev/null 2>&1; then
        mkdir -p /run/sshd /root/.ssh
        chmod 700 /root/.ssh
        
        # Generate host keys if missing
        if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
          echo "[zypi] Generating SSH host keys..."
          ssh-keygen -A >/dev/null 2>&1 || true
        fi
        
        # Setup passwordless root login
        # Allow root login with key only
        mkdir -p /etc/ssh
        echo 'Port 22
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM no
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server' > /etc/ssh/sshd_config
        
        # Read authorized_keys from zypi config if present
        if [ -f /etc/zypi/authorized_keys ]; then
          cp /etc/zypi/authorized_keys /root/.ssh/authorized_keys
          chmod 600 /root/.ssh/authorized_keys
          echo "[zypi] SSH keys configured"
        fi
        
        # Start SSH daemon
        /usr/sbin/sshd -D &
        SSHD_PID=$!
        echo "[zypi] SSH server started (PID: $SSHD_PID)"
      else
        echo "[zypi] WARNING: Could not install SSH server"
      fi
    }
    
    setup_ssh
    
    #{main_process_section}
    
    # Keep init running (wait for any background process)
    echo "[zypi] Container ready"
    wait
    """
  end

  defp shell_escape(args) when is_list(args) do
    Enum.map_join(args, " ", &"'#{String.replace(&1, "'", "'\\''")}'")
  end

  defp copy_rootfs(src, dst) do
    files = (Path.wildcard("#{src}/*") ++ Path.wildcard("#{src}/.*"))
            |> Enum.reject(&(Path.basename(&1) in [".", ".."]))
    if files != [], do: System.cmd("cp", ["-a"] ++ files ++ [dst], stderr_to_stdout: true)
    :ok
  end

  defp losetup(path) do
    case System.cmd("losetup", ["--find", "--show", path], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {err, code} -> {:error, {:losetup_failed, code, err}}
    end
  end
end
