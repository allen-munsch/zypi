defmodule Zypi.Cluster.Membership do
  @moduledoc """
  Manages cluster membership.

  Handles node join/leave events and maintains the cluster topology.
  """

  use GenServer
  require Logger

  alias Zypi.Store.Nodes
  alias Zypi.Cluster.Gossip

  @node_timeout_ms 30_000
  @check_interval_ms 5_000

  defstruct [
    :node_id,
    members: MapSet.new()
  ]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Join the cluster via a seed node.
  """
  def join(seed_host, seed_port) do
    GenServer.call(__MODULE__, {:join, seed_host, seed_port})
  end

  @doc """
  Leave the cluster gracefully.
  """
  def leave do
    GenServer.call(__MODULE__, :leave)
  end

  @doc """
  Get current cluster members.
  """
  def members do
    GenServer.call(__MODULE__, :members)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    node_id = Nodes.local_node_id()

    # Register self in cluster
    announce_self()

    # Start membership check timer
    schedule_check()

    Logger.info("Zypi.Cluster.Membership initialized")

    {:ok, %__MODULE__{
      node_id: node_id,
      members: MapSet.new([node_id])
    }}
  end

  @impl true
  def handle_call({:join, seed_host, seed_port}, _from, state) do
    Gossip.add_peer(seed_host, seed_port)
    announce_self()
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:leave, _from, state) do
    announce_leave()
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:members, _from, state) do
    {:reply, MapSet.to_list(state.members), state}
  end

  @impl true
  def handle_info(:check_members, state) do
    state = check_member_health(state)
    schedule_check()
    {:noreply, state}
  end

  @impl true
  def handle_info({:node_joined, node_id, node_info}, state) do
    Logger.info("Node joined: #{node_id}")

    # Add to store
    Nodes.put(struct(Zypi.Store.Nodes.Node, node_info))

    # Add to members
    members = MapSet.put(state.members, node_id)

    {:noreply, %{state | members: members}}
  end

  @impl true
  def handle_info({:node_left, node_id}, state) do
    Logger.info("Node left: #{node_id}")

    # Remove from store
    Nodes.delete(node_id)

    # Remove from members
    members = MapSet.delete(state.members, node_id)

    {:noreply, %{state | members: members}}
  end

  # Private Functions

  defp schedule_check do
    Process.send_after(self(), :check_members, @check_interval_ms)
  end

  defp announce_self do
    node_info = %{
      id: Nodes.local_node_id(),
      host: local_host(),
      port: Application.get_env(:zypi, :port, 4000),
      region: Application.get_env(:zypi, :region, "default"),
      status: :healthy,
      last_heartbeat: DateTime.utc_now()
    }

    Gossip.broadcast({:node, node_info.id}, node_info)
  end

  defp announce_leave do
    node_id = Nodes.local_node_id()
    Gossip.broadcast({:node_leave, node_id}, DateTime.utc_now())
  end

  defp check_member_health(state) do
    now = DateTime.utc_now()

    # Check all known nodes
    Nodes.list()
    |> Enum.each(fn node ->
      if node.id != state.node_id do
        age_ms = DateTime.diff(now, node.last_heartbeat, :millisecond)

        if age_ms > @node_timeout_ms do
          Logger.warning("Node #{node.id} appears down (last seen #{age_ms}ms ago)")
          Nodes.update(node.id, %{status: :down})
        end
      end
    end)

    # Update members from store
    healthy = Nodes.list_healthy() |> Enum.map(& &1.id) |> MapSet.new()
    %{state | members: healthy}
  end

  defp local_host do
    Application.get_env(:zypi, :host, "127.0.0.1")
  end
end
