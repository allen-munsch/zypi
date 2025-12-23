defmodule Zypi.Pool.VMPool do
  @moduledoc """
  Pre-warmed VM pool for sub-200ms container starts.
  """

  use GenServer
  require Logger

  alias Zypi.Container.RuntimeFirecracker
  alias Zypi.Pool.IPPool

  @default_min_warm 3
  @default_max_warm 10
  @default_max_total 50
  @warm_check_interval 5_000

  defmodule VMSlot do
    defstruct [
      :id,
      :vm_state,
      :ip,
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
        recycles: 0
      }
    ]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def acquire(container_id, opts \\ []) do
    GenServer.call(__MODULE__, {:acquire, container_id, opts}, 10_000)
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

    Process.send_after(self(), :check_warm_pool, @warm_check_interval)
    send(self(), :initial_warmup)

    Logger.info("VMPool started: min_warm=#{state.min_warm}, max_warm=#{state.max_warm}")
    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, container_id, opts}, _from, state) do
    image = Keyword.get(opts, :image)

    case find_warm_vm(state, image) do
      {:ok, vm_id} ->
        state = assign_vm(state, vm_id, container_id)
        vm = Map.get(state.vms, vm_id)
        Logger.info("VMPool: Warm hit for #{container_id}, using VM #{vm_id}")
        state = update_metrics(state, :warm_hits)
        {:reply, {:ok, vm}, state}

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
  def handle_info({:vm_booted, vm_id, result}, state) do
    state = %{state | pending_boots: max(0, state.pending_boots - 1)}

    case result do
      {:ok, vm_state, ip} ->
        vm = %VMSlot{
          id: vm_id,
          vm_state: vm_state,
          ip: ip,
          status: :warm,
          image: nil,
          created_at: DateTime.utc_now()
        }

        state = %{state | 
          vms: Map.put(state.vms, vm_id, vm),
          warm_queue: state.warm_queue ++ [vm_id]
        }

        state = update_metrics(state, :total_boots)
        Logger.info("VMPool: VM #{vm_id} booted and warm")
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
        container = %{
          id: vm_id,
          ip: ip,
          rootfs: base_rootfs_path(),
          resources: %{cpu: 1, memory_mb: 256}
        }

        case RuntimeFirecracker.start(container) do
          {:ok, vm_state} ->
            case wait_for_agent(ip) do
              :ok -> {:ok, vm_state, ip}
              {:error, reason} ->
                RuntimeFirecracker.stop(%{id: vm_id, pid: vm_state})
                IPPool.release(ip)
                {:error, {:agent_unhealthy, reason}}
            end
          {:error, reason} ->
            IPPool.release(ip)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:no_ip, reason}}
    end
  end

  defp wait_for_agent(ip) do
    {a, b, c, d} = ip
    ip_str = "#{a}.#{b}.#{c}.#{d}"

    Enum.reduce_while(1..30, :timeout, fn _, _acc ->
      case :gen_tcp.connect(String.to_charlist(ip_str), 9999, [:binary], 1000) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          {:halt, :ok}
        {:error, _} ->
          Process.sleep(500)
          {:cont, :timeout}
      end
    end)
    |> case do
      :ok -> :ok
      :timeout -> {:error, :timeout}
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
    {a, b, c, d} = vm.ip
    ip_str = "#{a}.#{b}.#{c}.#{d}"

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
    if vm.vm_state do
      RuntimeFirecracker.stop(%{id: vm.id, pid: vm.vm_state})
    end
    if vm.ip do
      IPPool.release(vm.ip)
    end
    RuntimeFirecracker.cleanup(vm.id)
  end

  defp base_rootfs_path do
    Path.join(Application.get_env(:zypi, :data_dir, "/var/lib/zypi"), "base-rootfs.ext4")
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
end
