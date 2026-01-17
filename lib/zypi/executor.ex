defmodule Zypi.Executor do
  @moduledoc """
  High-level execution interface for Zyppi.
  """

  require Logger
  alias Zypi.Container.Agent
  alias Zypi.Pool.VMPool
  alias Zypi.Pool.ImageStore

  @default_timeout 60
  @default_memory_mb 256
  @default_vcpus 1

  defmodule Result do
    defstruct [
      :exit_code,
      :stdout,
      :stderr,
      :duration_ms,
      :container_id,
      :timed_out,
      :signal
    ]
  end

  defmodule Session do
    defstruct [:id, :container_id, :image, :ip, :created_at]
  end

  @doc """
  Run a command in a sandboxed environment.
  """
  def run(cmd, opts \\ []) when is_list(cmd) do
    image = Keyword.fetch!(opts, :image)
    start_time = System.monotonic_time(:millisecond)

    with :ok <- ensure_image_ready(image),
         {:ok, container_id, ip} <- acquire_or_create_container(image, opts),
         :ok <- upload_files(container_id, Keyword.get(opts, :files, %{}), ip),
         {:ok, exec_result} <- execute_command(container_id, cmd, opts, ip) do
      duration_ms = System.monotonic_time(:millisecond) - start_time
      release_container(container_id)

      {:ok,
       %Result{
         exit_code: exec_result.exit_code,
         stdout: exec_result.stdout,
         stderr: exec_result.stderr,
         duration_ms: duration_ms,
         container_id: container_id,
         timed_out: exec_result.timed_out,
         signal: exec_result.signal
       }}
    else
      {:error, reason} = error ->
        Logger.error("Execution failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Run a shell command (convenience wrapper).
  """
  def shell(command, opts \\ []) when is_binary(command) do
    run(["/bin/sh", "-c", command], opts)
  end

  @doc """
  Create a long-lived execution session.
  """
  def session(image, opts \\ []) do
    with :ok <- ensure_image_ready(image),
         {:ok, container_id, ip} <- acquire_or_create_container(image, opts) do

      session = %Session{
        id: generate_session_id(),
        container_id: container_id,
        image: image,
        ip: ip,
        created_at: DateTime.utc_now()
      }

      {:ok, session}
    end
  end

  @doc """
  Execute a command in an existing session.
  """
  def session_exec(%Session{container_id: container_id, ip: ip}, cmd, opts \\ []) do
    execute_command(container_id, cmd, opts, ip)
  end

  @doc """
  Upload a file to a session's container.
  """
  def session_upload(%Session{container_id: container_id, ip: ip}, path, content) do
    Agent.write_file(container_id, path, content, ip: ip)
  end

  @doc """
  Download a file from a session's container.
  """
  def session_download(%Session{container_id: container_id, ip: ip}, path) do
    Agent.read_file(container_id, path, ip: ip)
  end

  @doc """
  Close a session, releasing resources.
  """
  def session_close(%Session{container_id: container_id}) do
    release_container(container_id)
  end

  # Private functions

  defp ensure_image_ready(image_ref) do
    if ImageStore.image_exists?(image_ref) do
      :ok
    else
      Logger.warning("Image #{image_ref} not found")
      {:error, {:image_not_found, image_ref}}
    end
  end

  defp acquire_or_create_container(image, opts) do
    container_id = generate_container_id()

    case VMPool.acquire(container_id, image: image) do
      {:ok, vm_slot} ->
        Logger.info("Acquired warm VM #{vm_slot.id} for #{container_id}")
        overlay_image(vm_slot, image, opts)
        # Return both container_id and the VM's IP
        {:ok, container_id, vm_slot.ip}

      {:cold, _reason} ->
        Logger.info("Cold booting container #{container_id}")
        cold_boot_container(container_id, image, opts)
    end
  end

  defp cold_boot_container(container_id, image, opts) do
    resources = %{
      cpu: Keyword.get(opts, :vcpus, @default_vcpus),
      memory_mb: Keyword.get(opts, :memory_mb, @default_memory_mb)
    }

    params = %{
      id: container_id,
      image: image,
      resources: resources
    }

    with {:ok, container} <- Zypi.Container.Manager.create(params),
         {:ok, _} <- Zypi.Container.Manager.start(container_id),
         :ok <- wait_for_agent(container_id) do
      {:ok, container_id, container.ip}
    end
  end

  defp overlay_image(vm_slot, image, _opts) do
    Logger.debug("Overlaying image #{image} on VM #{vm_slot.id}")
    :ok
  end

  defp upload_files(_container_id, files, _ip) when map_size(files) == 0, do: :ok
  defp upload_files(container_id, files, ip) do
    results =
      Enum.map(files, fn {path, content} ->
        case Agent.write_file(container_id, path, content, ip: ip) do
          {:ok, _} -> :ok
          error -> error
        end
      end)

    case Enum.find(results, &(&1 != :ok)) do
      nil -> :ok
      error -> error
    end
  end

  defp execute_command(container_id, cmd, opts, ip) do
    exec_opts =
      [
        env: Keyword.get(opts, :env, %{}),
        workdir: Keyword.get(opts, :workdir),
        stdin: Keyword.get(opts, :stdin),
        timeout: Keyword.get(opts, :timeout, @default_timeout),
        ip: ip
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    Agent.exec(container_id, cmd, exec_opts)
  end

  defp wait_for_agent(container_id) do
    Agent.wait_ready(container_id, 30_000)
  end

  defp release_container(container_id) do
    VMPool.release(container_id)
  end

  defp generate_container_id do
    "exec_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp generate_session_id do
    "sess_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end

defmodule Zypi.Executor.Sandbox do
  @moduledoc """
  Sandbox configuration builder with bwrap-like interface.
  """

  defstruct [
    image: nil,
    readonly_paths: [],
    tmpfs_paths: [],
    bind_mounts: %{},
    env: %{},
    workdir: "/",
    network: true,
    memory_mb: 256,
    vcpus: 1,
    timeout: 60,
    files: %{}
  ]

  def new(image), do: %__MODULE__{image: image}

  def readonly(sandbox, path), do: %{sandbox | readonly_paths: [path | sandbox.readonly_paths]}
  def tmpfs(sandbox, path), do: %{sandbox | tmpfs_paths: [path | sandbox.tmpfs_paths]}

  def bind(sandbox, host_path, guest_path) do
    %{sandbox | bind_mounts: Map.put(sandbox.bind_mounts, guest_path, host_path)}
  end

  def env(sandbox, key, value), do: %{sandbox | env: Map.put(sandbox.env, key, value)}
  def workdir(sandbox, path), do: %{sandbox | workdir: path}
  def no_network(sandbox), do: %{sandbox | network: false}
  def memory(sandbox, mb), do: %{sandbox | memory_mb: mb}
  def cpus(sandbox, n), do: %{sandbox | vcpus: n}
  def timeout(sandbox, seconds), do: %{sandbox | timeout: seconds}
  def file(sandbox, path, content), do: %{sandbox | files: Map.put(sandbox.files, path, content)}

  def run(%__MODULE__{} = sandbox, cmd) do
    opts = [
      image: sandbox.image,
      env: sandbox.env,
      workdir: sandbox.workdir,
      files: sandbox.files,
      timeout: sandbox.timeout,
      memory_mb: sandbox.memory_mb,
      vcpus: sandbox.vcpus,
      network: sandbox.network
    ]

    Zypi.Executor.run(cmd, opts)
  end
end
