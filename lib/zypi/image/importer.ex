defmodule Zypi.Image.Importer do
  use GenServer
  require Logger

  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")
  @base_dir "/opt/zypi/rootfs"
  @images_dir Path.join( @data_dir, "images")

  defmodule ContainerConfig do
    @derive Jason.Encoder
    defstruct [:cmd, :entrypoint, :env, :workdir, :user]
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def import_tar(ref, tar_data) do
    GenServer.call(__MODULE__, {:import, ref, tar_data}, 300_000)
  end

  @impl true
  def init(_opts) do
    File.mkdir_p!( @images_dir)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:import, ref, tar_data}, _from, state) do
    result = do_import(ref, tar_data)
    {:reply, result, state}
  end

  defp do_import(ref, tar_data) do
    Logger.info("Importer: Starting import for #{ref}")
    work_dir = Path.join( @data_dir, "imports/#{System.unique_integer([:positive])}")
    File.mkdir_p!(work_dir)

    try do
      tar_path = Path.join(work_dir, "image.tar")
      File.write!(tar_path, tar_data)

      with {:ok, image_dir} <- extract_tar(tar_path, Path.join(work_dir, "extracted")),
           {:ok, oci_config} <- parse_oci_config(image_dir),
           container_config = extract_container_config(oci_config),
           {:ok, docker_layers} <- get_docker_layers(image_dir),
           {:ok, base_ext4} <- find_base_ext4(),
           {:ok, ext4_path} <- build_ext4_image(ref, base_ext4, docker_layers, Map.from_struct(container_config)) do
        size_bytes = File.stat!(ext4_path).size
        Zypi.Pool.ImageStore.put_image(ref, ext4_path, Map.from_struct(container_config), size_bytes)
        Zypi.Store.Images.put(%Zypi.Store.Images.Image{ref: ref, status: :ready, device: ext4_path, size_bytes: size_bytes, pulled_at: DateTime.utc_now()})
        Logger.info("Import complete: #{ref} (#{size_bytes} bytes)")
        {:ok, %{ref: ref, ext4_path: ext4_path, size_bytes: size_bytes, container_config: container_config}}
      end
    after
      File.rm_rf!(work_dir)
    end
  end

  defp build_ext4_image(ref, base_ext4, docker_layers, container_config) do
  encoded = Base.url_encode64(ref, padding: false)
  ext4_path = Path.join(@images_dir, "#{encoded}.ext4")

  {_, 0} = System.cmd("cp", ["--reflink=auto", base_ext4, ext4_path], stderr_to_stdout: true)

  Enum.each(docker_layers, fn layer ->
    Logger.info("Applying layer: #{Path.basename(layer)}")
    {_, 0} = System.cmd("overlaybd-apply", [layer, ext4_path, "--raw"], stderr_to_stdout: true)
  end)

  # Inject init script and SSH keys
  :ok = inject_init(ext4_path, container_config)

  {:ok, ext4_path}
end

  defp extract_tar(tar_path, dest) do
    File.mkdir_p!(dest)
    case System.cmd("tar", ["xf", tar_path, "-C", dest], stderr_to_stdout: true) do
      {_, 0} -> {:ok, dest}
      {err, code} -> {:error, {:tar_extract_failed, code, err}}
    end
  end

  defp parse_oci_config(image_dir) do
    manifest_path = Path.join(image_dir, "manifest.json")
    with {:ok, data} <- File.read(manifest_path),
         [manifest | _] <- Jason.decode!(data),
         config_file when not is_nil(config_file) <- manifest["Config"],
         {:ok, config_data} <- File.read(Path.join(image_dir, config_file)) do
      {:ok, Jason.decode!(config_data)}
    else
      _ -> {:error, :config_parse_failed}
    end
  end

  defp extract_container_config(oci_config) do
    cfg = oci_config["config"] || %{}
    %ContainerConfig{
      cmd: cfg["Cmd"],
      entrypoint: cfg["Entrypoint"],
      env: cfg["Env"] || [],
      workdir: cfg["WorkingDir"] || "/",
      user: cfg["User"] || "root"
    }
  end

  defp get_docker_layers(image_dir) do
    manifest_path = Path.join(image_dir, "manifest.json")
    with {:ok, data} <- File.read(manifest_path),
         [manifest | _] <- Jason.decode!(data) do
      layers = Enum.map(manifest["Layers"] || [], &Path.join(image_dir, &1))
      {:ok, layers}
    else
      _ -> {:error, :layers_parse_failed}
    end
  end
  defp find_base_ext4 do
    case File.ls(@base_dir) do
      {:ok, files} ->
        case Enum.find(files, &String.ends_with?(&1, ".ext4")) do
          nil -> {:error, :no_base_ext4}
          file -> {:ok, Path.join(@base_dir, file)}
        end
      {:error, reason} -> {:error, {:base_dir_error, reason}}
    end
  end

  defp inject_init(ext4_path, container_config) do
    mount_point = "/tmp/zypi-mount-#{System.unique_integer([:positive])}"
    File.mkdir_p!(mount_point)

    try do
      {_, 0} = System.cmd("mount", ["-o", "loop", ext4_path, mount_point], stderr_to_stdout: true)

      # Create directories
      Enum.each(~w[sbin etc/zypi root/.ssh], fn dir ->
        File.mkdir_p!(Path.join(mount_point, dir))
      end)

      # Nuke Ubuntu's dynamic MOTD system
      File.write!(Path.join(mount_point, "etc/legal"), "")
      update_motd_dir = Path.join(mount_point, "etc/update-motd.d")
      File.rm_rf(update_motd_dir)
      File.mkdir_p!(update_motd_dir)

      # Write init script
      init_script = generate_init_script(container_config)
      init_path = Path.join(mount_point, "sbin/zypi-init")
      File.write!(init_path, init_script)
      File.chmod!(init_path, 0o755)

      # Symlink /sbin/init -> zypi-init
      sbin_init = Path.join(mount_point, "sbin/init")
      File.rm(sbin_init)
      File.ln_s!("zypi-init", sbin_init)

      # Copy SSH authorized keys
      ssh_key_path = Application.get_env(:zypi, :ssh_key_path)
      if ssh_key_path && File.exists?("#{ssh_key_path}.pub") do
        pub_key = File.read!("#{ssh_key_path}.pub")
        auth_keys = Path.join(mount_point, "root/.ssh/authorized_keys")
        File.write!(auth_keys, pub_key)
        File.chmod!(auth_keys, 0o600)
      end

      # Write container config
      config_path = Path.join(mount_point, "etc/zypi/config.json")
      File.write!(config_path, Jason.encode!(container_config))

      :ok
    after
      System.cmd("umount", [mount_point], stderr_to_stdout: true)
      File.rmdir(mount_point)
    end
  end

  defp generate_init_script(config) do
    entrypoint = Map.get(config, :entrypoint) || []
    cmd = Map.get(config, :cmd) || []
    env = Map.get(config, :env) || []
    workdir = Map.get(config, :workdir) || "/"

    env_exports = env |> Enum.map(&"export #{&1}") |> Enum.join("\n")

    main_cmd = case {entrypoint, cmd} do
      {[], []} -> nil
      {[], c} -> shell_escape(c)
      {e, []} -> shell_escape(e)
      {e, c} -> shell_escape(e ++ c)
    end

    main_section = if main_cmd, do: "cd #{workdir}\n(#{main_cmd}) &", else: "cd #{workdir}"

    """
    #!/bin/sh
    touch /var/log/lastlog
    mount -t proc proc /proc 2>/dev/null
    mount -t sysfs sysfs /sys 2>/dev/null
    mount -t devtmpfs devtmpfs /dev 2>/dev/null
    mkdir -p /dev/pts /dev/shm /run/sshd /var/log
    mount -t devpts devpts /dev/pts 2>/dev/null
    mount -t tmpfs tmpfs /run 2>/dev/null
    ip link set lo up 2>/dev/null
    ip link set eth0 up 2>/dev/null
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export HOME=/root
    rm -rf /etc/update-motd.d/* 2>/dev/null
    cat > /etc/motd << 'MOTD'
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║   ███████╗██╗   ██╗██████╗ ██╗                                ║
║   ╚══███╔╝╚██╗ ██╔╝██╔══██╗██║                                ║
║     ███╔╝  ╚████╔╝ ██████╔╝██║                                ║
║    ███╔╝    ╚██╔╝  ██╔═══╝ ██║                                ║
║   ███████╗   ██║   ██║     ██║                                ║
║   ╚══════╝   ╚═╝   ╚═╝     ╚═╝                                ║
║                                                               ║
║   ⚡ Firecracker microVM · Sub-second boot · CoW snapshots     ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝

MOTD

    #{env_exports}
    if [ -x /usr/sbin/sshd ]; then
      mkdir -p /run/sshd
      [ ! -f /etc/ssh/ssh_host_rsa_key ] && ssh-keygen -A 2>/dev/null
      /usr/sbin/sshd -D -e &
    fi
    #{main_section}
    while true; do sleep 60; done
    """
  end

  defp shell_escape(args) when is_list(args) do
    Enum.map_join(args, " ", &("'" <> String.replace(&1, "'", "'\\''") <> "'"))
  end
end
