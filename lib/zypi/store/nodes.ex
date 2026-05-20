defmodule Zypi.Store.Nodes do
  @moduledoc """
  ETS-backed cluster node state store.

  Stores information about all nodes in the cluster,
  updated via gossip protocol.
  """

  use GenServer
  require Logger

  @table :zypi_nodes

  defmodule Node do
    @enforce_keys [:id, :host]
    defstruct [
      :id,
      :host,
      :port,
      :region,
      :last_heartbeat,
      status: :unknown,
      resources: %{
        cpu_total: 0,
        cpu_used: 0,
        memory_total_mb: 0,
        memory_used_mb: 0,
        disk_total_mb: 0,
        disk_used_mb: 0
      },
      containers: [],
      metadata: %{}
    ]
  end

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get(node_id) do
    case :ets.lookup(@table, node_id) do
      [{^node_id, node}] -> {:ok, node}
      [] -> {:error, :not_found}
    end
  end

  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, node} -> node end)
  end

  def list_healthy do
    list() |> Enum.filter(&(&1.status == :healthy))
  end

  def list_by_region(region) do
    list() |> Enum.filter(&(&1.region == region))
  end

  def put(%Node{id: id} = node) do
    :ets.insert(@table, {id, node})
    :ok
  end

  def update(node_id, updates) when is_map(updates) do
    case get(node_id) do
      {:ok, node} ->
        updated = struct(node, updates)
        put(updated)
        {:ok, updated}

      {:error, _} = error ->
        error
    end
  end

  def delete(node_id) do
    :ets.delete(@table, node_id)
    :ok
  end

  def touch_heartbeat(node_id) do
    update(node_id, %{last_heartbeat: DateTime.utc_now(), status: :healthy})
  end

  def local_node_id do
    Application.get_env(:zypi, :node_id) || generate_node_id()
  end

  defp generate_node_id do
    {:ok, hostname} = :inet.gethostname()
    "node_#{hostname}"
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Register self
    register_local_node()

    Logger.info("Zypi.Store.Nodes initialized")
    {:ok, %{table: table}}
  end

  defp register_local_node do
    node = %Node{
      id: local_node_id(),
      host: local_host(),
      port: Application.get_env(:zypi, :port, 4000),
      region: Application.get_env(:zypi, :region, "default"),
      status: :healthy,
      last_heartbeat: DateTime.utc_now(),
      resources: collect_resources()
    }

    put(node)
  end

  defp local_host do
    Application.get_env(:zypi, :host) || 
      case :inet.getif() do
        {:ok, [{ip, _, _} | _]} -> ip |> :inet.ntoa() |> to_string()
        _ -> "127.0.0.1"
      end
  end

  defp collect_resources do
    %{
      cpu_total: System.schedulers_online(),
      cpu_used: 0,
      memory_total_mb: total_memory_mb(),
      memory_used_mb: 0,
      disk_total_mb: 0,
      disk_used_mb: 0
    }
  end

  defp total_memory_mb do
    case Zypi.System.Stats.memory_data() do
      data when is_list(data) ->
        total = Keyword.get(data, :total_memory, 0)
        div(total, 1024 * 1024)
      _ ->
        0
    end
  end
end
