defmodule Zypi.System.Cleanup do
  @moduledoc """
  System cleanup and lifecycle management.
  """

  use GenServer
  require Logger

  @cleanup_interval_ms 60_000
  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def run_cleanup do
    GenServer.call(__MODULE__, :run_cleanup, 30_000)
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl true
  def init(_opts) do
    do_cleanup()
    schedule_cleanup()

    {:ok, %{
      last_cleanup: DateTime.utc_now(),
      stats: %{
        tap_devices_cleaned: 0,
        iptables_rules_cleaned: 0,
        processes_killed: 0,
        dirs_cleaned: 0
      }
    }}
  end

  @impl true
  def handle_call(:run_cleanup, _from, state) do
    stats = do_cleanup()
    {:reply, {:ok, stats}, %{state | last_cleanup: DateTime.utc_now(), stats: stats}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    stats = do_cleanup()
    schedule_cleanup()
    {:noreply, %{state | last_cleanup: DateTime.utc_now(), stats: stats}}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp do_cleanup do
    Logger.debug("Running system cleanup")

    stats = %{
      tap_devices_cleaned: 0,
      iptables_rules_cleaned: 0,
      processes_killed: 0,
      dirs_cleaned: 0
    }

    active_ids = get_active_ids()
    Logger.debug("Cleanup: #{MapSet.size(active_ids)} active container/VM IDs")

    stats = cleanup_tap_devices(stats, active_ids)
    stats = cleanup_zombie_processes(stats, active_ids)
    stats = cleanup_stale_dirs(stats, active_ids)

    if stats.tap_devices_cleaned > 0 or
       stats.processes_killed > 0 or
       stats.dirs_cleaned > 0 do
      Logger.info("Cleanup complete: #{inspect(stats)}")
    end

    stats
  end

  @doc """
  Get all active container IDs AND warm VM IDs.
  This ensures we don't clean up warm VMs from the pool.
  """
  defp get_active_ids do
    # Get container IDs from store
    container_ids = Zypi.Store.Containers.list()
    |> Enum.filter(& &1.status in [:running, :starting, :created])
    |> Enum.map(& &1.id)

    # Get VM IDs from the warm pool - these should NOT be cleaned up
    vm_pool_ids = try do
      Zypi.Pool.VMPool.active_vm_ids()
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end

    Logger.debug("Cleanup: #{length(container_ids)} containers, #{length(vm_pool_ids)} pool VMs")

    MapSet.new(container_ids ++ vm_pool_ids)
  end

  defp cleanup_tap_devices(stats, _active_ids) do
    case System.cmd("ip", ["-o", "link", "show", "type", "tun"], stderr_to_stdout: true) do
      {output, 0} ->
        tap_devices = output
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case Regex.run(~r/^\d+:\s+(ztap\d+)/, line) do
            [_, tap_name] -> tap_name
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

        cleaned = tap_devices
        |> Enum.reduce(0, fn tap_name, count ->
          case Regex.run(~r/ztap(\d+)/, tap_name) do
            [_, _num] ->
              # Check if any container might use this tap
              # For safety, only clean taps older than 5 minutes
              Logger.debug("Found tap device: #{tap_name}")
              count
            _ ->
              count
          end
        end)

        %{stats | tap_devices_cleaned: cleaned}

      _ ->
        stats
    end
  end

  defp cleanup_zombie_processes(stats, active_ids) do
    case System.cmd("pgrep", ["-a", "-f", "firecracker.*api.sock"], stderr_to_stdout: true) do
      {output, _} ->
        cleaned = output
        |> String.split("\n", trim: true)
        |> Enum.reduce(0, fn line, count ->
          case Regex.run(~r/^(\d+).*\/vms\/([^\/]+)\//, line) do
            [_, pid_str, vm_or_container_id] ->
              # Check if this ID is in our active set (containers OR warm VMs)
              if not MapSet.member?(active_ids, vm_or_container_id) do
                pid = String.to_integer(pid_str)
                Logger.info("Killing orphaned Firecracker process #{pid} for #{vm_or_container_id}")
                System.cmd("kill", ["-9", "#{pid}"], stderr_to_stdout: true)
                count + 1
              else
                Logger.debug("Preserving active Firecracker process for #{vm_or_container_id}")
                count
              end
            _ -> count
          end
        end)

        %{stats | processes_killed: cleaned}

      _ ->
        stats
    end
  end

  defp cleanup_stale_dirs(stats, active_ids) do
    vms_dir = Path.join(@data_dir, "vms")
    containers_dir = Path.join(@data_dir, "containers")

    cleaned = cleanup_dir(vms_dir, active_ids) +
              cleanup_dir(containers_dir, active_ids)

    %{stats | dirs_cleaned: cleaned}
  end

  defp cleanup_dir(dir, active_ids) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reduce(0, fn entry, count ->
          path = Path.join(dir, entry)

          # Only clean if NOT in active IDs (containers or warm VMs)
          if File.dir?(path) and not MapSet.member?(active_ids, entry) do
            case File.stat(path) do
              {:ok, %{mtime: mtime}} ->
                mtime_dt = NaiveDateTime.from_erl!(mtime) |> DateTime.from_naive!("Etc/UTC")
                age_seconds = DateTime.diff(DateTime.utc_now(), mtime_dt)

                # Only clean directories older than 5 minutes
                if age_seconds > 300 do
                  Logger.info("Cleaning stale directory: #{path}")
                  File.rm_rf!(path)
                  count + 1
                else
                  Logger.debug("Preserving recent directory: #{path} (age: #{age_seconds}s)")
                  count
                end
              _ -> count
            end
          else
            count
          end
        end)
      {:error, :enoent} -> 0
      {:error, reason} ->
        Logger.warning("Failed to list directory #{dir}: #{inspect(reason)}")
        0
    end
  end
end
