defmodule Zypi.Image.Supervisor do
  @moduledoc """
  Supervises image management processes.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Zypi.Image.Delta.init()

    children = [
      Zypi.Image.Registry,
      Zypi.Image.Warmer
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
