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
  defp inject_container_init(rootfs_path, entrypoint, cmd) do
    # Mount the rootfs
    mount_point = Path.join(System.tmp_dir!(), "zypi-init-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(mount_point)

    try do
      {_, 0} = System.cmd("mount", ["-o", "loop", rootfs_path, mount_point])

      # Create init script that runs the container entrypoint
      init_script = """
      #!/bin/sh
      # Container init wrapper
      export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      export HOME=/root
      cd /
      exec #{build_exec_command(entrypoint, cmd)}
      """

      init_path = Path.join(mount_point, "init.sh")
      File.write!(init_path, init_script)
      File.chmod!(init_path, 0o755)

      :ok
    after
      System.cmd("umount", [mount_point], stderr_to_stdout: true)
      File.rmdir(mount_point)
    end
  end

  defp build_exec_command(nil, nil), do: "/bin/sh"
  defp build_exec_command(entrypoint, nil), do: Enum.join(entrypoint, " ")
  defp build_exec_command(nil, cmd), do: Enum.join(cmd, " ")
  defp build_exec_command(entrypoint, cmd), do: Enum.join(entrypoint ++ cmd, " ")
  defp inject_vm_init(rootfs_dir, config) do
    ~w[dev proc sys tmp run etc var/run sbin]
    |> Enum.each(&File.mkdir_p!(Path.join(rootfs_dir, &1)))

    File.mkdir_p!(Path.join(rootfs_dir, "etc/zypi"))
    File.write!(Path.join(rootfs_dir, "etc/zypi/config.json"), Jason.encode!(config))

    init_script = generate_init_script(config)
    init_path = Path.join(rootfs_dir, "sbin/zypi-init")
    File.write!(init_path, init_script)
    File.chmod!(init_path, 0o755)

    # Only create symlink if /sbin/init doesn't exist
    sbin_init = Path.join(rootfs_dir, "sbin/init")
    case File.lstat(sbin_init) do
      {:error, :enoent} ->
        # No init exists, create our symlink
        File.ln_s!("zypi-init", sbin_init)
      {:ok, _} ->
        # Something exists (file, symlink, etc.) - leave it alone
        # But we need to use our init, so overwrite it
        File.rm(sbin_init)
        File.ln_s!("zypi-init", sbin_init)
    end
    :ok
  end

  defp generate_init_script(config) do
    entrypoint = config[:entrypoint] || config["entrypoint"] || []
    cmd = config[:cmd] || config["cmd"] || []
    env = config[:env] || config["env"] || []
    workdir = config[:workdir] || config["workdir"] || "/"

    exec_cmd = case {entrypoint, cmd} do
      {[], []} -> "exec /bin/sh"
      {[], c} -> "exec #{shell_escape(c)}"
      {e, []} -> "exec #{shell_escape(e)}"
      {e, c} -> "exec #{shell_escape(e ++ c)}"
    end

    """
    #!/bin/sh
    set -e
    mount -t proc proc /proc 2>/dev/null || true
    mount -t sysfs sysfs /sys 2>/dev/null || true
    mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
    mkdir -p /dev/pts /dev/shm
    mount -t devpts devpts /dev/pts 2>/dev/null || true
    mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true
    mount -t tmpfs tmpfs /run 2>/dev/null || true
    ip link set lo up 2>/dev/null || true
    ip link set eth0 up 2>/dev/null || true
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    #{Enum.map(env, &"export #{&1}") |> Enum.join("\n")}
    cd #{workdir}
    #{exec_cmd}
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
