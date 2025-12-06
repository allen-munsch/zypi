defmodule Zypi.Application do
  @moduledoc """
  Zypi distributed container platform.
  """

  use Application

  @impl true
  def start(_type, _args) do
    Zypi.System.Stats.init()

    children = [
      Zypi.Store.Supervisor,
      Zypi.Pool.Supervisor,
      Zypi.Cluster.Supervisor,
      Zypi.Image.Supervisor,
      Zypi.Container.Supervisor,
      Zypi.Scheduler.Supervisor,
      Zypi.API.Supervisor,
      Zypi.API.ConsoleSocket # Add the new ConsoleSocket supervisor
    ]

    opts = [strategy: :one_for_one, name: Zypi.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
