defmodule Zypi.System.Stats do
  @moduledoc """
  System statistics from /proc filesystem.
  """
  require Logger

  @cpu_stats_table :zypi_cpu_stats

  def init do
    :ets.new(@cpu_stats_table, [:set, :public, :named_table])
    :ets.insert(@cpu_stats_table, {:prev_cpu_times, {0, 0}})
  end

  def cpu_util do
    case read_proc_stat() do
      {:ok, total_time, idle_time} ->
        case :ets.lookup(@cpu_stats_table, :prev_cpu_times) do
          [{:prev_cpu_times, {prev_total, prev_idle}}] ->
            total_diff = total_time - prev_total
            idle_diff = idle_time - prev_idle
            :ets.insert(@cpu_stats_table, {:prev_cpu_times, {total_time, idle_time}})
            if total_diff > 0, do: 100.0 - (idle_diff * 100.0 / total_diff), else: 0.0
          [] ->
            :ets.insert(@cpu_stats_table, {:prev_cpu_times, {total_time, idle_time}})
            0.0
        end
      {:error, reason} ->
        Logger.warning("Could not read /proc/stat: #{reason}")
        0.0
    end
  rescue
    ArgumentError -> 0.0
  end

  def cpu_avg1 do
    case File.read("/proc/loadavg") do
      {:ok, content} ->
        case String.split(content) do
          [avg1_str | _] ->
            case Float.parse(avg1_str) do
              {avg1, ""} -> avg1
              _ -> 0.0
            end
          _ -> 0.0
        end
      {:error, _} -> 0.0
    end
  end

  def memory_data do
    case File.read("/proc/meminfo") do
      {:ok, content} ->
        mem_info = content
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, ":", parts: 2))
        |> Enum.filter(&(length(&1) == 2))
        |> Enum.into(%{}, fn [k, v] ->
          {String.trim(k), v |> String.trim() |> String.split() |> hd() |> String.to_integer()}
        end)
        total_kb = Map.get(mem_info, "MemTotal", 0)
        free_kb = Map.get(mem_info, "MemFree", 0)
        [total_memory: total_kb * 1024, free_memory: free_kb * 1024]
      {:error, reason} ->
        Logger.error("Could not read /proc/meminfo: #{reason}")
        [total_memory: 0, free_memory: 0]
    end
  end

  defp read_proc_stat do
    case File.read("/proc/stat") do
      {:ok, content} ->
        [cpu_line | _] = String.split(content, "\n")
        [_label | times_str] = String.split(cpu_line)
        times = Enum.map(times_str, &String.to_integer/1)
        [_user, _nice, _system, idle | _] = times
        {:ok, Enum.sum(times), idle}
      {:error, reason} ->
        {:error, reason}
    end
  end
end
