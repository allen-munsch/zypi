defmodule Zypi.Pool.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Zypi.Pool.IPPool,
      Zypi.Pool.ImageStore,
      Zypi.Pool.VMPool
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end