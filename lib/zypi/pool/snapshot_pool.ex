defmodule Zypi.Pool.SnapshotPool do
  @moduledoc """
  Simple file-based CoW snapshots using cp --reflink.
  Falls back to regular copy if reflink not supported.
  """
  use GenServer
  require Logger

  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")
  @containers_dir Path.join(@data_dir, "containers")

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def create_snapshot(_image_ref, container_id, base_image_path) do
    GenServer.call(__MODULE__, {:snapshot, container_id, base_image_path}, 60_000)
  end

  def destroy_snapshot(_image_ref, container_id) do
    GenServer.call(__MODULE__, {:destroy, container_id})
  end

  @impl true
  def init(_opts) do
    File.mkdir_p!(@containers_dir)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:snapshot, container_id, base_image_path}, _from, state) do
    container_dir = Path.join(@containers_dir, container_id)
    rootfs_path = Path.join(container_dir, "rootfs.ext4")

    File.mkdir_p!(container_dir)

    Logger.info("SnapshotPool: Creating rootfs copy for #{container_id}")

    # Use dd for reliable block-level copy instead of cp --reflink
    result = case System.cmd("dd", [
      "if=#{base_image_path}",
      "of=#{rootfs_path}",
      "bs=4M",
      "conv=sparse"
    ], stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.info("SnapshotPool: Created rootfs for #{container_id}")
        {:ok, rootfs_path}
      {err, code} ->
        Logger.error("SnapshotPool: dd failed (#{code}): #{err}")
        {:error, {:dd_failed, code, err}}
    end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:destroy, container_id}, _from, state) do
    container_dir = Path.join(@containers_dir, container_id)
    File.rm_rf(container_dir)
    Logger.info("SnapshotPool: Destroyed #{container_id}")
    {:reply, :ok, state}
  end
end
