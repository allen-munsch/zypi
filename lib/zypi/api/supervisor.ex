defmodule Zypi.API.Supervisor do
  @moduledoc """
  Supervises API-related processes.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    port = Application.get_env(:zypi, :api_port, 4000)

    children = [
      {Bandit, plug: Zypi.API.Router, port: port}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
