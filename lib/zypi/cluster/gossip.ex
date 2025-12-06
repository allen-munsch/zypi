defmodule Zypi.Cluster.Gossip do
  @moduledoc """
  Gossip protocol for cluster state dissemination.

  Uses CRDTs to ensure eventual consistency across nodes.
  Each node maintains a local view that converges with peers.
  """

  use GenServer
  require Logger

  alias Zypi.Store.Nodes

  @gossip_interval_ms 1000
  @fanout 3

  defstruct [
    :node_id,
    :crdt,
    peers: [],
    pending_syncs: %{}
  ]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Broadcast a state update to the cluster.
  """
  def broadcast(key, value) do
    GenServer.cast(__MODULE__, {:broadcast, key, value})
  end

  @doc """
  Get current cluster state.
  """
  def state do
    GenServer.call(__MODULE__, :state)
  end

  @doc """
  Add a peer to gossip with.
  """
  def add_peer(host, port) do
    GenServer.cast(__MODULE__, {:add_peer, host, port})
  end

  @doc """
  Remove a peer.
  """
  def remove_peer(peer_id) do
    GenServer.cast(__MODULE__, {:remove_peer, peer_id})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    node_id = Nodes.local_node_id()

    # Initialize CRDT for cluster state
    {:ok, crdt} = DeltaCrdt.start_link(DeltaCrdt.AWLWWMap)

    # Start gossip timer
    schedule_gossip()

    Logger.info("Zypi.Cluster.Gossip initialized for #{node_id}")

    {:ok, %__MODULE__{
      node_id: node_id,
      crdt: crdt,
      peers: initial_peers()
    }}
  end

  @impl true
  def handle_cast({:broadcast, key, value}, state) do
    DeltaCrdt.put(state.crdt, key, value)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:add_peer, host, port}, state) do
    peer = %{host: host, port: port, id: "#{host}:#{port}"}
    peers = [peer | state.peers] |> Enum.uniq_by(& &1.id)
    {:noreply, %{state | peers: peers}}
  end

  @impl true
  def handle_cast({:remove_peer, peer_id}, state) do
    peers = Enum.reject(state.peers, &(&1.id == peer_id))
    {:noreply, %{state | peers: peers}}
  end

  @impl true
  def handle_call(:state, _from, state) do
    cluster_state = DeltaCrdt.to_map(state.crdt)
    {:reply, cluster_state, state}
  end

  @impl true
  def handle_info(:gossip, state) do
    state = do_gossip(state)
    schedule_gossip()
    {:noreply, state}
  end

  @impl true
  def handle_info({:sync_response, peer_id, delta}, state) do
    # Merge incoming delta
    DeltaCrdt.merge(state.crdt, delta)
    
    pending = Map.delete(state.pending_syncs, peer_id)
    {:noreply, %{state | pending_syncs: pending}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("Gossip received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Functions

  defp schedule_gossip do
    Process.send_after(self(), :gossip, @gossip_interval_ms)
  end

  defp do_gossip(state) do
    # Select random peers to gossip with
    targets = state.peers
    |> Enum.shuffle()
    |> Enum.take(@fanout)

    # Send state delta to each target
    delta = DeltaCrdt.to_map(state.crdt)

    Enum.each(targets, fn peer ->
      send_gossip(peer, delta, state.node_id)
    end)

    state
  end

  defp send_gossip(peer, delta, from_node) do
    # In production, use actual network transport
    # For now, if peer is local Erlang node, use direct message
    Task.start(fn ->
      case connect_peer(peer) do
        {:ok, pid} ->
          send(pid, {:gossip, from_node, delta})
        {:error, reason} ->
          Logger.debug("Failed to gossip to #{peer.id}: #{inspect(reason)}")
      end
    end)
  end

  defp connect_peer(%{host: host, port: port}) do
    # Simple TCP-based gossip
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 1000) do
      {:ok, socket} ->
        {:ok, socket}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp initial_peers do
    Application.get_env(:zypi, :seed_nodes, [])
    |> Enum.map(fn {host, port} ->
      %{host: host, port: port, id: "#{host}:#{port}"}
    end)
  end
end
