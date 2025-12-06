defmodule Zypi.Image.Warmer do
  @moduledoc """
  Warms device pools on startup and after delta pushes.
  """

  use GenServer
  require Logger

  alias Zypi.Image.Delta
  alias Zypi.Pool.DevicePool

  @warm_delay_ms 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def warm_all, do: GenServer.cast(__MODULE__, :warm_all)
  def warm(image_ref), do: GenServer.cast(__MODULE__, {:warm, image_ref})

  @impl true
  def init(_opts) do
    Process.send_after(self(), :startup_warm, @warm_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:startup_warm, state) do
    Logger.info("Warming device pools for #{length(Delta.list())} images")
    Enum.each(Delta.list(), &DevicePool.warm/1)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:warm_all, state) do
    Enum.each(Delta.list(), &DevicePool.warm/1)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:warm, image_ref}, state) do
    DevicePool.warm(image_ref)
    {:noreply, state}
  end
end
