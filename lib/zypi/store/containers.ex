defmodule Zypi.Store.Containers do
  @moduledoc """
  ETS-backed container state store.

  Provides fast, concurrent access to container state on this node.
  """

  use GenServer
  require Logger

  @table :zypi_containers

  # Data structure
  defmodule Container do
    @enforce_keys [:id, :image]
    defstruct [
      :id,
      :image,
      :pid,
      :rootfs,
      :ip,
      :created_at,
      :started_at,
      status: :pending,
      resources: %{cpu: 1, memory_mb: 256},
      metadata: %{}
    ]
  end

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get a container by ID.
  """
  def get(container_id) do
    case :ets.lookup(@table, container_id) do
      [{^container_id, container}] -> {:ok, container}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  List all containers.
  """
  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, container} -> container end)
  end

  @doc """
  List containers matching a filter.
  """
  def list(filter) when is_function(filter, 1) do
    list() |> Enum.filter(filter)
  end

  @doc """
  Insert or update a container.
  """
  def put(%Container{id: id} = container) do
    :ets.insert(@table, {id, container})
    :ok
  end

  @doc """
  Update a container field.
  """
  def update(container_id, updates) when is_map(updates) do
    case get(container_id) do
      {:ok, container} ->
        updated = struct(container, updates)
        put(updated)
        {:ok, updated}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Delete a container.
  """
  def delete(container_id) do
    :ets.delete(@table, container_id)
    :ok
  end

  @doc """
  Count containers by status.
  """
  def count_by_status do
    list()
    |> Enum.group_by(& &1.status)
    |> Enum.map(fn {status, containers} -> {status, length(containers)} end)
    |> Map.new()
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

    Logger.info("Zypi.Store.Containers initialized")
    {:ok, %{table: table}}
  end
end
