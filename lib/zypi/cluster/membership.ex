defmodule Zypi.Cluster.Membership do
  use GenServer
  require Logger

  alias Zypi.Store.Nodes

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def join(_seed_host, _seed_port), do: :ok
  def leave, do: :ok
  def members, do: [Nodes.local_node_id()]

  @impl true
  def init(_opts) do
    Logger.info("Cluster.Membership initialized (stub)")
    {:ok, %{}}
  end
end