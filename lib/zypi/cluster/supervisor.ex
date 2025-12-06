defmodule Zypi.Cluster.Supervisor do
  @moduledoc """
  Supervises cluster coordination processes.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Zypi.Cluster.Gossip,
      Zypi.Cluster.Membership,
      Zypi.Cluster.Heartbeat
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
