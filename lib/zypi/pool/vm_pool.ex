defmodule Zypi.Pool.VMPool do
  @moduledoc """
  Pre-warmed VM pool for sub-200ms container starts.

  Each warm VM gets its own copy of the base rootfs to prevent
  filesystem corruption from multiple VMs sharing the same ext4.
  """

  use GenServer
  require Logger

  alias Zypi.Runtime.Firecracker, as: RuntimeFirecracker
  alias Zypi.Pool.IPPool

  @default_min_warm 3
  @default_max_warm 10
  @default_max_total 50
  @warm_check_interval 5_000
  @health_check_interval 10_000
  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")

  defmodule VMSlot do
    defstruct [
      :id,
      :vm_state,
      :ip,
      :rootfs,  # Each VM has its own rootfs path
      :status,
      :image,
      :created_at,
      :assigned_at,
      :container_id
    ]
  end

  defmodule State do
    defstruct [
      :min_warm,
      :max_warm,
      :max_total,
      vms: %{},
      warm_queue: [],
      image_pools: %{},
      pending_boots: 0,
      metrics: %{
        total_boots: 0,
        warm_hits: 0,
        cold_misses: 0,
        recycles: 0,
        unhealthy_removed: 0
      }
    ]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def acquire(container_id, opts \\ []) do
    GenServer.call(__MODULE__, {:acquire, container_id, opts}, 15_000)
  end

  def release(container_id) do
    GenServer.cast(__MODULE__, {:release, container_id})
  end

  def destroy(vm_id) do
    GenServer.cast(__MODULE__, {:destroy, vm_id})
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Get list of all active VM IDs (for cleanup coordination).
  """
  def active_vm_ids do
    GenServer.call(__MODULE__, :active_vm_ids)
  end

  @doc """
  Get detailed info about all VMs.
  """
  def list_all_vms do
    GenServer.call(__MODULE__, :list_all_vms)
  end

  @doc """
  Check health of all VMs in the pool.
  """
  def check_all_vm_health do
    GenServer.call(__MODULE__, :check_all_vm_health, 30_000)
  end

  def warm_for_image(image_ref, count \\ 1) do
    GenServer.cast(__MODULE__, {:warm_for_image, image_ref, count})
  end

  @impl true
  def init(_opts) do
    config = Application.get_env(:zypi, :vm_pool, [])

    state = %State{
      min_warm: Keyword.get(config, :min_warm, @default_min_warm),
      max_warm: Keyword.get(config, :max_warm, @default_max_warm),
      max_total: Keyword.get(config, :max_total, @default_max_total)
    }

    # Schedule periodic checks
    Process.send_after(self(), :check_warm_pool, @warm_check_interval)
    Process.send_after(self(), :health_check_warm_vms, @health_check_interval)
    send(self(), :initial_warmup)

    Logger.info("VMPool started: min_warm=#{state.min_warm}, max_warm=#{state.max_warm}")
    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, container_id, opts}, from, state) do
    image = Keyword.get(opts, :image)

    case find_and_verify_warm_vm(state, image) do
      {:ok, vm_id, vm} ->
        state = assign_vm(state, vm_id, container_id)
        Logger.info("VMPool: Warm hit for #{container_id}, using VM #{vm_id} with IP #{format_ip(vm.ip)}")
        state = update_metrics(state, :warm_hits)
        {:reply, {:ok, vm}, state}

      {:unhealthy, vm_id} ->
        Logger.warning("VMPool: VM #{vm_id} unhealthy during acquire, removing and retrying")
        state = do_destroy(state, vm_id)
        state = update_metrics(state, :unhealthy_removed)
        # Recurse to try next VM
        handle_call({:acquire, container_id, opts}, from, state)

      :none ->
        Logger.info("VMPool: Cold miss for #{container_id}")
        state = update_metrics(state, :cold_misses)
        {:reply, {:cold, :no_warm_vms}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    warm_count = length(state.warm_queue)
    assigned_count = state.vms
      |> Map.values()
      |> Enum.count(& &1.status == :assigned)

    stats = %{
      warm: warm_count,
      assigned: assigned_count,
      total: map_size(state.vms),
      pending_boots: state.pending_boots,
      metrics: state.metrics,
      by_image: Enum.map(state.image_pools, fn {img, ids} -> {img, length(ids)} end) |> Map.new()
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:active_vm_ids, _from, state) do
    ids = Map.keys(state.vms)
    {:reply, ids, state}
  end

  @impl true
  def handle_call(:list_all_vms, _from, state) do
    vms = Enum.map(state.vms, fn {id, vm} ->
      %{
        id: id,
        ip: format_ip(vm.ip),
        rootfs: vm.rootfs,
        status: vm.status,
        container_id: vm.container_id,
        created_at: vm.created_at
      }
    end)
    {:reply, vms, state}
  end

  @impl true
  def handle_call(:check_all_vm_health, _from, state) do
    results = Enum.map(state.vms, fn {id, vm} ->
      ip_str = format_ip(vm.ip)
      health = ping_agent(vm.ip)
      %{
        id: id,
        ip: ip_str,
        status: vm.status,
        health: health,
        rootfs_exists: vm.rootfs && File.exists?(vm.rootfs)
      }
    end)
    {:reply, results, state}
  end

  @impl true
  def handle_cast({:release, container_id}, state) do
    case find_vm_by_container(state, container_id) do
      {:ok, vm_id, vm} ->
        state = do_release(state, vm_id, vm)
        {:noreply, state}
      :not_found ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:destroy, vm_id}, state) do
    state = do_destroy(state, vm_id)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:warm_for_image, image_ref, count}, state) do
    state = spawn_warm_vms(state, count, image_ref)
    {:noreply, state}
  end

  @impl true
  def handle_info(:initial_warmup, state) do
    Logger.info("VMPool: Initial warmup, spawning #{state.min_warm} VMs")
    state = spawn_warm_vms(state, state.min_warm, nil)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_warm_pool, state) do
    warm_count = length(state.warm_queue)
    needed = state.min_warm - warm_count - state.pending_boots

    state = if needed > 0 and total_count(state) < state.max_total do
      Logger.debug("VMPool: Warm pool low (#{warm_count}), spawning #{needed}")
      spawn_warm_vms(state, needed, nil)
    else
      state
    end

    Process.send_after(self(), :check_warm_pool, @warm_check_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:health_check_warm_vms, state) do
    state = check_warm_vm_health(state)
    Process.send_after(self(), :health_check_warm_vms, @health_check_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info({:vm_booted, vm_id, result}, state) do
    state = %{state | pending_boots: max(0, state.pending_boots - 1)}

    case result do
      {:ok, vm_state, ip, rootfs} ->
        vm = %VMSlot{
          id: vm_id,
          vm_state: vm_state,
          ip: ip,
          rootfs: rootfs,
          status: :warm,
          image: nil,
          created_at: DateTime.utc_now()
        }

        state = %{state |
          vms: Map.put(state.vms, vm_id, vm),
          warm_queue: state.warm_queue ++ [vm_id]
        }

        state = update_metrics(state, :total_boots)
        Logger.info("VMPool: VM #{vm_id} booted and warm at #{format_ip(ip)}")
        {:noreply, state}

      {:error, reason} ->
        Logger.error("VMPool: VM #{vm_id} boot failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:vm_recycled, vm_id, result}, state) do
    case result do
      :ok ->
        state = case Map.get(state.vms, vm_id) do
          nil -> state
          vm ->
            vm = %{vm | status: :warm, container_id: nil, assigned_at: nil}
            %{state |
              vms: Map.put(state.vms, vm_id, vm),
              warm_queue: state.warm_queue ++ [vm_id]
            }
        end

        state = update_metrics(state, :recycles)
        Logger.info("VMPool: VM #{vm_id} recycled")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("VMPool: VM #{vm_id} recycle failed, destroying: #{inspect(reason)}")
        state = do_destroy(state, vm_id)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("VMPool: Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  defp find_and_verify_warm_vm(state, image) do
    case find_warm_vm(state, image) do
      {:ok, vm_id} ->
        vm = Map.get(state.vms, vm_id)
        case ping_agent(vm.ip) do
          :ok -> {:ok, vm_id, vm}
          {:error, _reason} -> {:unhealthy, vm_id}
        end
      :none -> :none
    end
  end

  defp ping_agent(ip) do
    ip_str = format_ip(ip)
    case :gen_tcp.connect(String.to_charlist(ip_str), 9999, [:binary], 2000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_warm_vm_health(state) do
    # Only check VMs in the warm queue (not assigned ones)
    {healthy, unhealthy} = Enum.split_with(state.warm_queue, fn vm_id ->
      vm = Map.get(state.vms, vm_id)
      vm && ping_agent(vm.ip) == :ok
    end)

    if length(unhealthy) > 0 do
      Logger.warning("VMPool: Removing #{length(unhealthy)} unhealthy warm VMs: #{inspect(unhealthy)}")

      Enum.each(unhealthy, fn vm_id ->
        vm = Map.get(state.vms, vm_id)
        if vm, do: spawn(fn -> destroy_vm(vm) end)
      end)

      %{state |
        warm_queue: healthy,
        vms: Map.drop(state.vms, unhealthy),
        metrics: Map.update(state.metrics, :unhealthy_removed, length(unhealthy), & &1 + length(unhealthy))
      }
    else
      state
    end
  end

  defp find_warm_vm(state, image) do
    if image do
      case Map.get(state.image_pools, image, []) do
        [vm_id | _] -> {:ok, vm_id}
        [] -> find_generic_warm_vm(state)
      end
    else
      find_generic_warm_vm(state)
    end
  end

  defp find_generic_warm_vm(state) do
    case state.warm_queue do
      [vm_id | _] -> {:ok, vm_id}
      [] -> :none
    end
  end

  defp assign_vm(state, vm_id, container_id) do
    vm = Map.get(state.vms, vm_id)
    vm = %{vm |
      status: :assigned,
      container_id: container_id,
      assigned_at: DateTime.utc_now()
    }

    %{state |
      vms: Map.put(state.vms, vm_id, vm),
      warm_queue: List.delete(state.warm_queue, vm_id),
      image_pools: remove_from_image_pool(state.image_pools, vm.image, vm_id)
    }
  end

  defp remove_from_image_pool(pools, nil, _vm_id), do: pools
  defp remove_from_image_pool(pools, image, vm_id) do
    case Map.get(pools, image) do
      nil -> pools
      ids -> Map.put(pools, image, List.delete(ids, vm_id))
    end
  end

  defp find_vm_by_container(state, container_id) do
    case Enum.find(state.vms, fn {_id, vm} -> vm.container_id == container_id end) do
      {vm_id, vm} -> {:ok, vm_id, vm}
      nil -> :not_found
    end
  end

  defp do_release(state, vm_id, vm) do
    warm_count = length(state.warm_queue)

    if warm_count < state.max_warm do
      vm = %{vm | status: :recycling}
      state = %{state | vms: Map.put(state.vms, vm_id, vm)}
      spawn_recycle(vm_id, vm)
      state
    else
      do_destroy(state, vm_id)
    end
  end

  defp do_destroy(state, vm_id) do
    case Map.get(state.vms, vm_id) do
      nil -> state
      vm ->
        spawn(fn -> destroy_vm(vm) end)

        %{state |
          vms: Map.delete(state.vms, vm_id),
          warm_queue: List.delete(state.warm_queue, vm_id),
          image_pools: remove_from_image_pool(state.image_pools, vm.image, vm_id)
        }
    end
  end

  defp spawn_warm_vms(state, count, image) when count > 0 do
    parent = self()

    Enum.reduce(1..count, state, fn _, acc ->
      vm_id = generate_vm_id()

      Task.start(fn ->
        result = boot_warm_vm(vm_id, image)
        send(parent, {:vm_booted, vm_id, result})
      end)

      %{acc | pending_boots: acc.pending_boots + 1}
    end)
  end
  defp spawn_warm_vms(state, _count, _image), do: state

  defp boot_warm_vm(vm_id, _image) do
    case IPPool.acquire() do
      {:ok, ip} ->
        # Create a dedicated rootfs copy for this VM
        case create_vm_rootfs(vm_id) do
          {:ok, rootfs_path} ->
            container = %{
              id: vm_id,
              ip: ip,
              rootfs: rootfs_path,
              resources: %{cpu: 1, memory_mb: 256}
            }

            case RuntimeFirecracker.start(container) do
              {:ok, vm_state} ->
                case wait_for_agent(ip) do
                  :ok -> {:ok, vm_state, ip, rootfs_path}
                  {:error, reason} ->
                    RuntimeFirecracker.stop(%{id: vm_id, pid: vm_state})
                    IPPool.release(ip)
                    cleanup_vm_rootfs(vm_id)
                    {:error, {:agent_unhealthy, reason}}
                end
              {:error, reason} ->
                IPPool.release(ip)
                cleanup_vm_rootfs(vm_id)
                {:error, reason}
            end

          {:error, reason} ->
            IPPool.release(ip)
            {:error, {:rootfs_copy_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:no_ip, reason}}
    end
  end

  @doc """
  Create a copy-on-write snapshot of the base rootfs for a specific VM.
  """
  defp create_vm_rootfs(vm_id) do
    base_rootfs = base_rootfs_path()
    vm_dir = Path.join(@data_dir, "vms/#{vm_id}")
    File.mkdir_p!(vm_dir)
    vm_rootfs = Path.join(vm_dir, "rootfs.ext4")

    Logger.debug("VMPool: Creating rootfs copy for #{vm_id}: #{base_rootfs} -> #{vm_rootfs}")

    # Use reflink for instant CoW copy if supported, falls back to regular copy
    case System.cmd("cp", ["--reflink=auto", "--sparse=always", base_rootfs, vm_rootfs],
                    stderr_to_stdout: true) do
      {_, 0} ->
        Logger.debug("VMPool: Rootfs copy created for #{vm_id} (#{File.stat!(vm_rootfs).size} bytes)")
        {:ok, vm_rootfs}
      {output, code} ->
        Logger.error("VMPool: Failed to copy rootfs for #{vm_id}: exit #{code}, #{output}")
        {:error, {:copy_failed, code, output}}
    end
  end

  defp cleanup_vm_rootfs(vm_id) do
    vm_dir = Path.join(@data_dir, "vms/#{vm_id}")
    File.rm_rf(vm_dir)
  end

  defp wait_for_agent(ip) do
    ip_str = format_ip(ip)

    Logger.debug("VMPool: Waiting for agent at #{ip_str}:9999")

    result =
      Enum.reduce_while(1..30, {:timeout, 0}, fn attempt, {_, _} ->
        case :gen_tcp.connect(String.to_charlist(ip_str), 9999, [:binary], 1000) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            Logger.debug("VMPool: Agent responded on attempt #{attempt}")
            {:halt, {:ok, attempt}}
          {:error, reason} ->
            if rem(attempt, 5) == 0 do
              Logger.debug(
                "VMPool: Agent not ready at #{ip_str}:9999, attempt #{attempt}/30, reason: #{inspect(reason)}"
              )
            end

            Process.sleep(500)
            {:cont, {:timeout, attempt}}
        end
      end)

    case result do
      {:ok, _attempt} ->
        :ok
      {:timeout, last_attempt} ->
        Logger.warning(
          "VMPool: Agent never responded after #{last_attempt} attempts at #{ip_str}:9999"
        )

        {:error, :timeout}
    end
  end

  defp spawn_recycle(vm_id, vm) do
    parent = self()

    Task.start(fn ->
      result = recycle_vm(vm)
      send(parent, {:vm_recycled, vm_id, result})
    end)
  end

  defp recycle_vm(vm) do
    ip_str = format_ip(vm.ip)

    with {:ok, socket} <- :gen_tcp.connect(String.to_charlist(ip_str), 9999, [:binary, active: false, packet: :line], 5000),
         :ok <- :gen_tcp.send(socket, Jason.encode!(%{id: "1", method: "exec", params: %{cmd: ["pkill", "-9", "-u", "nobody"]}}) <> "\n"),
         {:ok, _} <- :gen_tcp.recv(socket, 0, 5000),
         :ok <- :gen_tcp.send(socket, Jason.encode!(%{id: "2", method: "exec", params: %{cmd: ["rm", "-rf", "/tmp/*"]}}) <> "\n"),
         {:ok, _} <- :gen_tcp.recv(socket, 0, 5000),
         :ok <- :gen_tcp.send(socket, Jason.encode!(%{id: "3", method: "health", params: %{}}) <> "\n"),
         {:ok, health_resp} <- :gen_tcp.recv(socket, 0, 5000) do
      :gen_tcp.close(socket)

      case Jason.decode(health_resp) do
        {:ok, %{"result" => %{"status" => "healthy"}}} -> :ok
        _ -> {:error, :unhealthy_after_recycle}
      end
    else
      error -> {:error, error}
    end
  end

  defp destroy_vm(vm) do
    Logger.debug("VMPool: Destroying VM #{vm.id}")

    if vm.vm_state do
      RuntimeFirecracker.stop(%{id: vm.id, pid: vm.vm_state})
    end
    if vm.ip do
      IPPool.release(vm.ip)
    end

    # Clean up VM-specific rootfs
    cleanup_vm_rootfs(vm.id)

    RuntimeFirecracker.cleanup(vm.id)
  end

  defp base_rootfs_path do
    "/opt/zypi/rootfs/ubuntu-24.04.ext4"
  end

  defp generate_vm_id do
    "vm_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp total_count(state) do
    map_size(state.vms) + state.pending_boots
  end

  defp update_metrics(state, key) do
    %{state | metrics: Map.update(state.metrics, key, 1, & &1 + 1)}
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip) when is_binary(ip), do: ip
end
