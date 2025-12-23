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

    active_containers = get_active_container_ids()

    stats = cleanup_tap_devices(stats, active_containers)
    stats = cleanup_zombie_processes(stats, active_containers)
    stats = cleanup_stale_dirs(stats, active_containers)

    if stats.tap_devices_cleaned > 0 or
       stats.processes_killed > 0 or
       stats.dirs_cleaned > 0 do
      Logger.info("Cleanup complete: #{inspect(stats)}")
    end

    stats
  end

  defp get_active_container_ids do
    Zypi.Store.Containers.list()
    |> Enum.filter(& &1.status in [:running, :starting, :created])
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp cleanup_tap_devices(stats, _active_containers) do
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

  defp cleanup_zombie_processes(stats, active_containers) do
    case System.cmd("pgrep", ["-a", "-f", "firecracker.*api.sock"], stderr_to_stdout: true) do
      {output, _} ->
        cleaned = output
        |> String.split("\n", trim: true)
        |> Enum.reduce(0, fn line, count ->
          case Regex.run(~r/^(\d+).*\/vms\/([^\/]+)\//, line) do
            [_, pid_str, container_id] ->
              if not MapSet.member?(active_containers, container_id) do
                pid = String.to_integer(pid_str)
                Logger.info("Killing orphaned Firecracker process #{pid} for #{container_id}")
                System.cmd("kill", ["-9", "#{pid}"], stderr_to_stdout: true)
                count + 1
              else
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

  defp cleanup_stale_dirs(stats, active_containers) do
    vms_dir = Path.join(@data_dir, "vms")
    containers_dir = Path.join(@data_dir, "containers")

    cleaned = cleanup_dir(vms_dir, active_containers) +
              cleanup_dir(containers_dir, active_containers)

    %{stats | dirs_cleaned: cleaned}
  end

  defp cleanup_dir(dir, active_containers) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reduce(0, fn entry, count ->
          path = Path.join(dir, entry)

          if File.dir?(path) and not MapSet.member?(active_containers, entry) do
            case File.stat(path) do
              {:ok, %{mtime: mtime}} ->
                mtime_dt = NaiveDateTime.from_erl!(mtime) |> DateTime.from_naive!("Etc/UTC")
                age_seconds = DateTime.diff(DateTime.utc_now(), mtime_dt)

                if age_seconds > 300 do
                  Logger.info("Cleaning stale directory: #{path}")
                  File.rm_rf!(path)
                  count + 1
                else
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
