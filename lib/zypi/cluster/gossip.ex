defmodule Zypi.Cluster.Gossip do
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def broadcast(_key, _value), do: :ok
  def state, do: %{}
  def add_peer(_host, _port), do: :ok
  def remove_peer(_peer_id), do: :ok

  @impl true
  def init(_opts) do
    Logger.info("Cluster.Gossip initialized (stub)")
    {:ok, %{}}
  end
end