defmodule Zypi.Store.Images do
  @moduledoc """
  ETS-backed image state store.
  """

  use GenServer
  require Logger

  @table :zypi_images

  defmodule Image do
    @enforce_keys [:ref]
    defstruct [
      :ref,
      :device,
      :size_bytes,
      :pulled_at,
      :manifest,
      status: :unknown,
      layers: []
    ]
  end

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get(image_ref) do
    case :ets.lookup(@table, image_ref) do
      [{^image_ref, image}] -> {:ok, image}
      [] -> {:error, :not_found}
    end
  end

  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {_ref, image} -> image end)
  end

  def put(%Image{ref: ref} = image) do
    :ets.insert(@table, {ref, image})
    :ok
  end

  def update(image_ref, updates) when is_map(updates) do
    case get(image_ref) do
      {:ok, image} ->
        updated = struct(image, updates)
        put(updated)
        {:ok, updated}

      {:error, _} = error ->
        error
    end
  end

  def delete(image_ref) do
    :ets.delete(@table, image_ref)
    :ok
  end

  def ready?(image_ref) do
    case get(image_ref) do
      {:ok, %{status: :ready}} -> true
      _ -> false
    end
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    Logger.info("Zypi.Store.Images initialized")
    {:ok, %{table: table}}
  end
end
