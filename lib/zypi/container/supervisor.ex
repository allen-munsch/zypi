defmodule Zypi.Container.Supervisor do
  @moduledoc """
  Supervises container processes.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: Zypi.Container.DynamicSupervisor, strategy: :one_for_one},
      Zypi.Container.Manager
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
