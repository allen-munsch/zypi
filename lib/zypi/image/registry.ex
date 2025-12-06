defmodule Zypi.Image.Registry do
  use GenServer
  require Logger

  alias Zypi.Image.Delta
  alias Zypi.Pool.DevicePool

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def get_device(image_ref) do
    DevicePool.acquire(image_ref)
  end

  def available?(image_ref) do
    case Delta.get(image_ref) do
      {:ok, _} -> true
      _ -> false
    end
  end

  def list do
    Delta.list()
  end

  @impl true
  def init(_opts) do
    Logger.info("Zypi.Image.Registry initialized")
    {:ok, %{}}
  end
end