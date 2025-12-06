# defmodule Zypi.Pool.ThinPool do
#   @moduledoc """
#   Device-mapper thin provisioning for copy-on-write container snapshots.
#   """
#   use GenServer
#   require Logger

#   @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")
#   @pool_dir Path.join(@data_dir, "thin")
#   @metadata_size_mb 64
#   @chunk_sectors 128

#   defstruct pools: %{}

#   def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

#   def setup_image_pool(image_ref, base_device) do
#     GenServer.call(__MODULE__, {:setup, image_ref, base_device}, 120_000)  # 2 min timeout
#   end

#   def create_snapshot(image_ref, container_id) do
#     GenServer.call(__MODULE__, {:snapshot, image_ref, container_id}, 30_000)
#   end

#   def destroy_snapshot(image_ref, container_id) do
#     GenServer.call(__MODULE__, {:destroy, image_ref, container_id})
#   end

#   @impl true
#   def init(_opts) do
#     File.mkdir_p!(@pool_dir)
#     {:ok, %__MODULE__{}}
#   end

#   @impl true
#   def handle_call({:setup, image_ref, base_device}, _from, state) do
#     case Map.get(state.pools, image_ref) do
#       nil ->
#         case do_setup_pool(image_ref, base_device) do
#           {:ok, pool_info} ->
#             pools = Map.put(state.pools, image_ref, pool_info)
#             {:reply, :ok, %{state | pools: pools}}
#           {:error, _} = error ->
#             {:reply, error, state}
#         end
#       _exists ->
#         Logger.debug("ThinPool: Pool already in memory for #{image_ref}")
#         {:reply, :ok, state}
#     end
#   end

#   @impl true
#   def handle_call({:snapshot, image_ref, container_id}, _from, state) do
#     case Map.get(state.pools, image_ref) do
#       nil ->
#         {:reply, {:error, :pool_not_found}, state}
#       pool_info ->
#         case do_create_snapshot(pool_info, container_id) do
#           {:ok, device} ->
#             {:reply, {:ok, device}, state}
#           {:error, _} = error ->
#             {:reply, error, state}
#         end
#     end
#   end

#   @impl true
#   def handle_call({:destroy, _image_ref, container_id}, _from, state) do
#     snap_name = "zypi-snap-#{container_id}"
#     System.cmd("dmsetup", ["remove", "--force", snap_name], stderr_to_stdout: true)
#     {:reply, :ok, state}
#   end

#   # ==========================================================================
#   # Pool Setup
#   # ==========================================================================

#   defp do_setup_pool(image_ref, base_device) do
#     pool_name = pool_name(image_ref)
#     base_vol_name = "#{pool_name}-base"

#     Logger.info("ThinPool: Setting up pool #{pool_name} from #{base_device}")

#     case check_existing_pool(pool_name, base_vol_name) do
#       {:ok, pool_info} ->
#         Logger.info("ThinPool: Reusing existing pool #{pool_name}")
#         {:ok, pool_info}

#       :not_found ->
#         Logger.info("ThinPool: Creating new pool #{pool_name}")
#         create_new_pool(image_ref, base_device, pool_name, base_vol_name)

#       :needs_cleanup ->
#         Logger.info("ThinPool: Cleaning up stale pool #{pool_name}")
#         cleanup_pool_full(pool_name, base_vol_name)
#         create_new_pool(image_ref, base_device, pool_name, base_vol_name)
#     end
#   end

#   defp check_existing_pool(pool_name, base_vol_name) do
#     pool_exists = dm_exists?(pool_name)
#     base_exists = dm_exists?(base_vol_name)

#     Logger.debug("ThinPool: check_existing_pool - pool=#{pool_exists}, base=#{base_exists}")

#     cond do
#       pool_exists and base_exists ->
#         case System.cmd("blockdev", ["--getsz", "/dev/mapper/#{base_vol_name}"], stderr_to_stdout: true) do
#           {output, 0} ->
#             size = output |> String.trim() |> String.to_integer()
#             {:ok, %{
#               pool_name: pool_name,
#               base_vol_name: base_vol_name,
#               base_thin_id: 0,
#               size_sectors: size
#             }}
#           _ ->
#             :needs_cleanup
#         end

#       pool_exists or base_exists ->
#         :needs_cleanup

#       true ->
#         meta_path = Path.join(@pool_dir, "#{pool_name}.meta")
#         data_path = Path.join(@pool_dir, "#{pool_name}.data")

#         if has_loop_attached?(meta_path) or has_loop_attached?(data_path) do
#           :needs_cleanup
#         else
#           :not_found
#         end
#     end
#   end

#   defp dm_exists?(name) do
#     match?({_, 0}, System.cmd("dmsetup", ["info", name], stderr_to_stdout: true))
#   end

#   defp has_loop_attached?(path) do
#     case System.cmd("losetup", ["-j", path], stderr_to_stdout: true) do
#       {output, 0} when output != "" -> true
#       _ -> false
#     end
#   end

#   defp create_new_pool(_image_ref, base_device, pool_name, base_vol_name) do
#     Logger.info("ThinPool: Step 1 - Getting device size")
#     with {:ok, size_sectors} <- get_device_sectors(base_device) do
#       Logger.info("ThinPool: Base device size: #{size_sectors} sectors (#{div(size_sectors, 2048)}MB)")

#       Logger.info("ThinPool: Step 2 - Creating pool devices")
#       with {:ok, meta_loop, data_loop, data_sectors} <- create_pool_devices(pool_name, size_sectors) do
#         Logger.info("ThinPool: Created meta=#{meta_loop}, data=#{data_loop}")

#         Logger.info("ThinPool: Step 3 - Creating thin-pool DM device")
#         with :ok <- create_thin_pool_dm(pool_name, meta_loop, data_loop, data_sectors) do
#           Logger.info("ThinPool: Thin pool created")

#           Logger.info("ThinPool: Step 4 - Creating base thin volume")
#           with :ok <- create_base_thin_volume(pool_name, base_vol_name, size_sectors) do
#             Logger.info("ThinPool: Base volume created")

#             Logger.info("ThinPool: Step 5 - Copying base image")
#             with :ok <- copy_base_image_to_thin(base_device, base_vol_name, size_sectors) do
#               Logger.info("ThinPool: Pool #{pool_name} ready (#{div(size_sectors, 2048)}MB)")

#               {:ok, %{
#                 pool_name: pool_name,
#                 base_vol_name: base_vol_name,
#                 base_thin_id: 0,
#                 size_sectors: size_sectors
#               }}
#             end
#           end
#         end
#       end
#     end
#     |> case do
#       {:ok, _} = success -> success
#       {:error, reason} = err ->
#         Logger.error("ThinPool setup failed: #{inspect(reason)}")
#         cleanup_pool_full(pool_name, base_vol_name)
#         err
#     end
#   end

#   defp create_pool_devices(pool_name, data_size_sectors) do
#     metadata_path = Path.join(@pool_dir, "#{pool_name}.meta")
#     data_path = Path.join(@pool_dir, "#{pool_name}.data")

#     metadata_bytes = @metadata_size_mb * 1024 * 1024
#     data_sectors = data_size_sectors * 3
#     data_bytes = data_sectors * 512

#     with :ok <- create_sparse_file(metadata_path, metadata_bytes),
#          :ok <- create_sparse_file(data_path, data_bytes),
#          {:ok, meta_loop} <- losetup(metadata_path),
#          {:ok, data_loop} <- losetup(data_path) do
#       # Zero metadata - use smaller block for speed
#       {_, _} = System.cmd("dd", ["if=/dev/zero", "of=#{meta_loop}", "bs=512", "count=8", "conv=notrunc"], stderr_to_stdout: true)
#       {:ok, meta_loop, data_loop, data_sectors}
#     end
#   end

#   defp create_sparse_file(path, size_bytes) do
#     File.rm(path)
#     case System.cmd("truncate", ["-s", "#{size_bytes}", path], stderr_to_stdout: true) do
#       {_, 0} -> :ok
#       {err, code} -> {:error, {:truncate_failed, path, code, err}}
#     end
#   end

#   defp create_thin_pool_dm(pool_name, meta_device, data_device, data_sectors) do
#     table = "0 #{data_sectors} thin-pool #{meta_device} #{data_device} #{@chunk_sectors} 0"

#     case System.cmd("dmsetup", ["create", pool_name, "--table", table], stderr_to_stdout: true) do
#       {_, 0} -> :ok
#       {err, code} -> {:error, {:thin_pool_create_failed, code, err}}
#     end
#   end

#   # ==========================================================================
#   # Base Thin Volume
#   # ==========================================================================

#   defp create_base_thin_volume(pool_name, base_vol_name, size_sectors) do
#     pool_device = "/dev/mapper/#{pool_name}"
#     base_thin_id = 0

#     # Create thin volume
#     case System.cmd("dmsetup", ["message", pool_device, "0", "create_thin #{base_thin_id}"], stderr_to_stdout: true) do
#       {_, 0} ->
#         # Activate it
#         table = "0 #{size_sectors} thin #{pool_device} #{base_thin_id}"
#         case System.cmd("dmsetup", ["create", base_vol_name, "--table", table], stderr_to_stdout: true) do
#           {_, 0} ->
#             # Verify device exists
#             target = "/dev/mapper/#{base_vol_name}"
#             Process.sleep(100)  # Let udev settle
#             if File.exists?(target) do
#               :ok
#             else
#               {:error, {:base_vol_not_found, target}}
#             end
#           {err, code} ->
#             {:error, {:base_vol_create_failed, code, err}}
#         end
#       {err, code} ->
#         {:error, {:create_thin_msg_failed, code, err}}
#     end
#   end

#   defp copy_base_image_to_thin(source_device, base_vol_name, size_sectors) do
#     target_device = "/dev/mapper/#{base_vol_name}"
#     size_mb = div(size_sectors * 512, 1024 * 1024)

#     # Verify devices exist
#     cond do
#       not File.exists?(source_device) ->
#         {:error, {:source_not_found, source_device}}

#       not File.exists?(target_device) ->
#         {:error, {:target_not_found, target_device}}

#       true ->
#         Logger.info("ThinPool: dd #{source_device} -> #{target_device} (#{size_mb}MB)")

#         start_time = System.monotonic_time(:millisecond)

#         result = System.cmd("dd", [
#           "if=#{source_device}",
#           "of=#{target_device}",
#           "bs=1M",
#           "conv=fsync,notrunc"
#         ], stderr_to_stdout: true)

#         elapsed = System.monotonic_time(:millisecond) - start_time
#         Logger.info("ThinPool: dd completed in #{elapsed}ms")

#         case result do
#           {output, 0} ->
#             Logger.debug("ThinPool: dd output: #{output}")
#             :ok
#           {err, code} ->
#             {:error, {:dd_copy_failed, code, err}}
#         end
#     end
#   end

#   # ==========================================================================
#   # Container Snapshots
#   # ==========================================================================

#   defp do_create_snapshot(pool_info, container_id) do
#     snap_name = "zypi-snap-#{container_id}"
#     pool_device = "/dev/mapper/#{pool_info.pool_name}"

#     if dm_exists?(snap_name) do
#       Logger.debug("ThinPool: Snapshot #{snap_name} already exists")
#       {:ok, "/dev/mapper/#{snap_name}"}
#     else
#       snap_thin_id = :erlang.phash2(container_id, 1_000_000) + 1000

#       case System.cmd("dmsetup", [
#              "message", pool_device, "0",
#              "create_snap #{snap_thin_id} #{pool_info.base_thin_id}"
#            ], stderr_to_stdout: true) do
#         {_, 0} ->
#           table = "0 #{pool_info.size_sectors} thin #{pool_device} #{snap_thin_id}"
#           case System.cmd("dmsetup", ["create", snap_name, "--table", table], stderr_to_stdout: true) do
#             {_, 0} ->
#               Logger.info("ThinPool: Created snapshot #{snap_name}")
#               {:ok, "/dev/mapper/#{snap_name}"}
#             {err, code} ->
#               {:error, {:snapshot_activate_failed, code, err}}
#           end
#         {err, code} ->
#           {:error, {:create_snap_failed, code, err}}
#       end
#     end
#   end

#   # ==========================================================================
#   # Cleanup
#   # ==========================================================================

#   defp cleanup_pool_full(pool_name, base_vol_name) do
#     Logger.debug("ThinPool: Full cleanup of #{pool_name}")

#     # Remove snapshots
#     {dm_list, _} = System.cmd("dmsetup", ["ls"], stderr_to_stdout: true)
#     dm_list
#     |> String.split("\n", trim: true)
#     |> Enum.filter(&String.starts_with?(&1, "zypi-snap-"))
#     |> Enum.each(fn line ->
#       [name | _] = String.split(line)
#       System.cmd("dmsetup", ["remove", "--force", name], stderr_to_stdout: true)
#     end)

#     System.cmd("dmsetup", ["remove", "--force", base_vol_name], stderr_to_stdout: true)
#     System.cmd("dmsetup", ["remove", "--force", pool_name], stderr_to_stdout: true)

#     meta_path = Path.join(@pool_dir, "#{pool_name}.meta")
#     data_path = Path.join(@pool_dir, "#{pool_name}.data")

#     detach_loops_for_file(meta_path)
#     detach_loops_for_file(data_path)

#     File.rm(meta_path)
#     File.rm(data_path)

#     Process.sleep(200)
#     :ok
#   end

#   defp detach_loops_for_file(path) do
#     case System.cmd("losetup", ["-j", path], stderr_to_stdout: true) do
#       {output, 0} when output != "" ->
#         output
#         |> String.split("\n", trim: true)
#         |> Enum.each(fn line ->
#           [device | _] = String.split(line, ":")
#           System.cmd("losetup", ["-d", String.trim(device)], stderr_to_stdout: true)
#         end)
#       _ ->
#         :ok
#     end
#   end

#   # ==========================================================================
#   # Helpers
#   # ==========================================================================

#   defp get_device_sectors(device) do
#     case System.cmd("blockdev", ["--getsz", device], stderr_to_stdout: true) do
#       {output, 0} -> {:ok, output |> String.trim() |> String.to_integer()}
#       {err, code} -> {:error, {:blockdev_failed, code, err}}
#     end
#   end

#   defp losetup(path) do
#     case System.cmd("losetup", ["-j", path], stderr_to_stdout: true) do
#       {output, 0} when output != "" ->
#         [device | _] = String.split(output, ":")
#         {:ok, String.trim(device)}
#       _ ->
#         case System.cmd("losetup", ["--find", "--show", path], stderr_to_stdout: true) do
#           {output, 0} -> {:ok, String.trim(output)}
#           {err, code} -> {:error, {:losetup_failed, code, err}}
#         end
#     end
#   end

#   defp pool_name(image_ref) do
#     hash = :crypto.hash(:sha256, image_ref) |> Base.encode16(case: :lower) |> String.slice(0, 12)
#     "zypi-pool-#{hash}"
#   end
# end
