defmodule Zypi.Cluster.Heartbeat do
  @moduledoc """
  Sends periodic heartbeats to the cluster.
  """

  use GenServer
  require Logger

  alias Zypi.Store.Nodes
  alias Zypi.Cluster.Gossip

  @heartbeat_interval_ms 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_heartbeat()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    send_heartbeat()
    schedule_heartbeat()
    {:noreply, state}
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
  end

  defp send_heartbeat do
    node_id = Nodes.local_node_id()

    heartbeat = %{
      node_id: node_id,
      timestamp: DateTime.utc_now(),
      resources: collect_resources(),
      containers: container_summary()
    }

    Gossip.broadcast({:heartbeat, node_id}, heartbeat)
    Nodes.touch_heartbeat(node_id)
  end

  defp collect_resources do
    %{
      cpu_used: Zypi.System.Stats.cpu_util(),
      memory_used_mb: memory_used_mb(),
      load_avg: Zypi.System.Stats.cpu_avg1()
    }
  end

  defp memory_used_mb do
    case Zypi.System.Stats.memory_data() do
      data when is_list(data) ->
        free = Keyword.get(data, :free_memory, 0)
        total = Keyword.get(data, :total_memory, 0)
        div(total - free, 1024 * 1024)
      _ ->
        0
    end
  end

  defp container_summary do
    Zypi.Store.Containers.count_by_status()
  end
end
