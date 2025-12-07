defmodule Zypi.Scheduler.Placement do
  use GenServer
  require Logger

  alias Zypi.Store.Nodes
  alias Zypi.Pool.ImageStore

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def select_node(params), do: GenServer.call(__MODULE__, {:select, params})

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:select, params}, _from, state) do
    {:reply, do_select(params), state}
  end

  defp do_select(params) do
    image = params[:image]
    region = params[:region]
    resources = params[:resources] || %{cpu: 1, memory_mb: 256}

    candidates = Nodes.list_healthy()
    |> filter_by_region(region)
    |> filter_by_resources(resources)
    |> score_nodes(image)
    |> Enum.sort_by(& &1.score, :desc)

    case candidates do
      [best | _] -> {:ok, best.node}
      [] -> {:error, :no_available_nodes}
    end
  end

  defp filter_by_region(nodes, nil), do: nodes
  defp filter_by_region(nodes, region), do: Enum.filter(nodes, &(&1.region == region))

  defp filter_by_resources(nodes, required) do
    Enum.filter(nodes, fn node ->
      res = node.resources
      available_cpu = res.cpu_total - res.cpu_used
      available_mem = res.memory_total_mb - res.memory_used_mb
      available_cpu >= required.cpu and available_mem >= required.memory_mb
    end)
  end

  defp score_nodes(nodes, image) do
    Enum.map(nodes, fn node ->
      image_score = if image_on_node?(image, node.id), do: 100, else: 0
      res = node.resources
      cpu_score = (res.cpu_total - res.cpu_used) * 10
      mem_score = div(res.memory_total_mb - res.memory_used_mb, 100)
      %{node: node, score: image_score + cpu_score + mem_score}
    end)
  end

  defp image_on_node?(image, node_id) do
    if node_id == Nodes.local_node_id() do
      ImageStore.image_exists?(image)
    else
      false
    end
  end
end