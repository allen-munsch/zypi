defmodule Zypi.Pool.IPPool do
  use GenServer
  require Logger

  @default_subnet {10, 0, 0, 0}
  @default_size 254

  defstruct [:subnet, :available, :allocated]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def acquire, do: GenServer.call(__MODULE__, :acquire)
  def release(ip), do: GenServer.cast(__MODULE__, {:release, ip})

  @impl true
  def init(_opts) do
    config = Application.get_env(:zypi, :pool, [])
    {a, b, c, _} = Keyword.get(config, :ip_subnet, @default_subnet)
    size = Keyword.get(config, :ip_pool_size, @default_size)

    available = for i <- 2..size, do: {a, b, c, i}
    {:ok, %__MODULE__{subnet: {a, b, c}, available: available, allocated: MapSet.new()}}
  end

  @impl true
  def handle_call(:acquire, _from, state) do
    case state.available do
      [ip | rest] ->
        state = %{state | available: rest, allocated: MapSet.put(state.allocated, ip)}
        {:reply, {:ok, ip}, state}
      [] ->
        {:reply, {:error, :pool_exhausted}, state}
    end
  end

  @impl true
  def handle_cast({:release, ip}, state) do
    if MapSet.member?(state.allocated, ip) do
      state = %{state | available: [ip | state.available], allocated: MapSet.delete(state.allocated, ip)}
      {:noreply, state}
    else
      {:noreply, state}
    end
  end
end
