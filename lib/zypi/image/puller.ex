defmodule Zypi.Image.Puller do
  @moduledoc """
  Background image puller for pre-warming.
  """
  use GenServer
  require Logger

  alias Zypi.Image.Warmer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def queue(image_ref, priority \\ :normal) do
    GenServer.cast(__MODULE__, {:queue, image_ref, priority})
  end

  def queue_many(image_refs), do: Enum.each(image_refs, &queue/1)

  @impl true
  def init(_opts), do: {:ok, %{queue: :queue.new()}}

  @impl true
  def handle_cast({:queue, image_ref, priority}, state) do
    Logger.info("Queueing image pull: #{image_ref}")
    queue = case priority do
      :high -> :queue.in_r(image_ref, state.queue)
      _ -> :queue.in(image_ref, state.queue)
    end
    send(self(), :process)
    {:noreply, %{state | queue: queue}}
  end

  @impl true
  def handle_info(:process, state) do
    case :queue.out(state.queue) do
      {{:value, image_ref}, queue} ->
        Warmer.warm(image_ref)
        send(self(), :process)
        {:noreply, %{state | queue: queue}}
      {:empty, _} ->
        {:noreply, state}
    end
  end
end
