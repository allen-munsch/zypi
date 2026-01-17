defmodule Zypi.Image.Importer do
  @telemetry_prefix [:zypi, :import]
  use GenServer
  require Logger


  @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")
  @base_dir "/opt/zypi/rootfs"
  @images_dir Path.join( @data_dir, "images")
  @base_ext4_cache_key :zypi_base_ext4_cache
  @max_concurrent_imports 2
  @max_layer_retries 3
  @retry_base_delay_ms 500
  @cleanup_interval_ms 300_000  # 5 minutes
  @stale_import_threshold_hours 1

  defmodule State do
    defstruct active_imports: %{}, queue: :queue.new(), max_concurrent: 2
  end

  defmodule ContainerConfig do
    @derive Jason.Encoder
    defstruct [:cmd, :entrypoint, :env, :workdir, :user]
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def import_tar(ref, tar_data) do
    GenServer.call(__MODULE__, {:queue_import, ref, tar_data}, :infinity)
  end

  @doc "Synchronous import for cases where blocking is acceptable."
  def import_tar_sync(ref, tar_data) do
    Task.Supervisor.async_nolink(Zypi.ImporterTasks, fn ->
      do_import(ref, tar_data)
    end)
    |> Task.await(300_000)
  end

  @impl true
  def init(_opts) do
    File.mkdir_p!( @images_dir)
    :persistent_term.put( @base_ext4_cache_key, {nil, nil})

    # Schedule periodic cleanup
    Process.send_after(self(), :cleanup_stale, @cleanup_interval_ms)

    # Run initial cleanup
    cleanup_stale_imports()

    {:ok, %State{max_concurrent: @max_concurrent_imports}}
  end

  @impl true
  def handle_call({:queue_import, ref, tar_data}, from, state) do
    # Store initial status
    Zypi.Store.Images.put(%Zypi.Store.Images.Image{
      ref: ref,
      status: :queued,
      pulled_at: DateTime.utc_now()
    })

    if map_size(state.active_imports) < state.max_concurrent do
      # Start immediately
      state = start_import(ref, tar_data, from, state)
      {:noreply, state}
    else
      # Queue for later
      Logger.info("Import queued for #{ref}, #{:queue.len(state.queue)} in queue")
      queue = :queue.in({ref, tar_data, from}, state.queue)
      {:noreply, %{state | queue: queue}}
    end
  end

  @impl true
  def handle_info({:import_complete, ref, _result}, state) do
    Logger.info("Import #{ref} completed, checking queue")

    # Remove from active
    state = %{state | active_imports: Map.delete(state.active_imports, ref)}

    # Process next in queue if any
    state = maybe_start_next(state)

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup_stale, state) do
    cleanup_stale_imports()
    Process.send_after(self(), :cleanup_stale, @cleanup_interval_ms)
    {:noreply, state}
  end

# Handle Task.async_nolink completion messages
 @impl true
def handle_info({ref, result}, state) when is_reference(ref) do
  # Flush the DOWN message from the task
  Process.demonitor(ref, [:flush])

  Logger.debug("Task completed with result: #{inspect(result, limit: 200)}")

  case result do
    {:ok, %{ref: image_ref}} ->
      Logger.info("Import task for #{image_ref} completed successfully")
    {:error, reason} ->
      Logger.warning("Import task failed: #{inspect(reason)}")
    other ->
      Logger.debug("Task returned: #{inspect(other, limit: 200)}")
  end

  {:noreply, state}
end

# Handle Task process DOWN messages
 @impl true
def handle_info({:DOWN, ref, :process, pid, reason}, state) when is_reference(ref) do
  case reason do
    :normal ->
      Logger.debug("Task process #{inspect(pid)} exited normally")
    :killed ->
      Logger.warning("Task process #{inspect(pid)} was killed")
    other ->
      Logger.error("Task process #{inspect(pid)} crashed: #{inspect(other)}")
  end
  {:noreply, state}
end

# Catch-all for unexpected messages - log but don't crash
 @impl true
def handle_info(msg, state) do
  Logger.warning("Importer received unexpected message: #{inspect(msg, limit: 500)}")
  {:noreply, state}
end

  defp cleanup_stale_imports do
    Logger.debug("Running stale import cleanup")

    # Clean up stale work directories
    imports_dir = Path.join( @data_dir, "imports")
    cleanup_stale_directories(imports_dir)

    # Clean up orphaned cache files (no corresponding image in store)
    cleanup_orphaned_cache_files()

    # Mark stale importing images as failed
    cleanup_stale_image_statuses()
  end

  defp cleanup_stale_directories(imports_dir) do
    case File.ls(imports_dir) do
      {:ok, dirs} ->
        threshold = DateTime.add(DateTime.utc_now(), - @stale_import_threshold_hours, :hour)

        Enum.each(dirs, fn dir ->
          dir_path = Path.join(imports_dir, dir)
          case File.stat(dir_path) do
            {:ok, %{mtime: mtime}} ->
              mtime_dt = NaiveDateTime.from_erl!(mtime) |> DateTime.from_naive!("Etc/UTC")
              if DateTime.compare(mtime_dt, threshold) == :lt do
                Logger.info("Cleaning up stale import directory: #{dir}")
                File.rm_rf!(dir_path)
              end
            _ ->
              :ok
          end
        end)
      {:error, :enoent} ->
        :ok
      {:error, reason} ->
        Logger.warning("Failed to list imports directory: #{inspect(reason)}")
    end
  end

  defp cleanup_orphaned_cache_files do
    case File.ls( @images_dir) do
      {:ok, files} ->
        cache_files = Enum.filter(files, &String.starts_with?(&1, "cache-"))
        image_files = Enum.filter(files, &String.ends_with?(&1, ".ext4"))
        |> Enum.reject(&String.starts_with?(&1, "cache-"))

        # Get layer hashes from existing images
        _valid_hashes = image_files
        |> Enum.map(fn f ->
          Path.join( @images_dir, f)
        end)
        |> MapSet.new()

        # For now, just log - could implement full orphan detection
        Logger.debug("Found #{length(cache_files)} cache files, #{length(image_files)} image files")
      _ ->
        :ok
    end
  end

  defp cleanup_stale_image_statuses do
    threshold = DateTime.add(DateTime.utc_now(), - @stale_import_threshold_hours, :hour)

    Zypi.Store.Images.list()
    |> Enum.filter(fn image ->
      image.status in [:importing, :queued, :extracting, :applying_layers] and
      image.pulled_at != nil and
      DateTime.compare(image.pulled_at, threshold) == :lt
    end)
    |> Enum.each(fn image ->
      Logger.warning("Marking stale import as failed: #{image.ref}")
      Zypi.Store.Images.mark_failed(image.ref, :stale_import_timeout)
    end)
  end

  defp start_import(ref, tar_data, from, state) do
    Zypi.Store.Images.update(ref, %{status: :importing})

    parent = self()
    task = Task.Supervisor.async_nolink(Zypi.ImporterTasks, fn ->
      result = do_import(ref, tar_data)
      send(parent, {:import_complete, ref, result})
      GenServer.reply(from, {:ok, :accepted, ref})
      result
    end)

    %{state | active_imports: Map.put(state.active_imports, ref, task)}
  end

  defp maybe_start_next(state) do
    if map_size(state.active_imports) < state.max_concurrent do
      case :queue.out(state.queue) do
        {{:value, {ref, tar_data, from}}, queue} ->
          Logger.info("Starting queued import for #{ref}")
          state = %{state | queue: queue}
          start_import(ref, tar_data, from, state)
        {:empty, _} ->
          state
      end
    else
      state
    end
  end

  defp apply_layer_with_retry(layer, ext4_path, attempt \\ 1) do
    layer_name = Path.basename(layer)

    case System.cmd("overlaybd-apply", [layer, ext4_path, "--raw"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, exit_code} when attempt < @max_layer_retries ->
        delay = @retry_base_delay_ms * :math.pow(2, attempt - 1) |> round()
        Logger.warning("Layer #{layer_name} failed (attempt #{attempt}/#{ @max_layer_retries}), retrying in #{delay}ms. Exit code: #{exit_code}, Output: #{String.slice(output, 0, 500)}")
        Process.sleep(delay)
        apply_layer_with_retry(layer, ext4_path, attempt + 1)

      {output, exit_code} ->
        Logger.error("Layer #{layer_name} failed after #{ @max_layer_retries} attempts. Exit code: #{exit_code}")
        Logger.error("Layer path: #{layer}")
        Logger.error("Target: #{ext4_path}")
        Logger.error("Output: #{output}")
        {:error, {:layer_failed, layer_name, exit_code, output}}
    end
  end



  defp do_import(ref, tar_data) do
    start_time = System.monotonic_time()
    metadata = %{ref: ref, size_bytes: byte_size(tar_data)}

    :telemetry.execute( @telemetry_prefix ++ [:start], %{system_time: System.system_time()}, metadata)

    result = do_import_internal(ref, tar_data)

    duration = System.monotonic_time() - start_time
    status = if match?({:ok, _}, result), do: :ok, else: :error
    :telemetry.execute( @telemetry_prefix ++ [:stop], %{duration: duration}, Map.put(metadata, :status, status))

    result
  end

  defp do_import_internal(ref, tar_data) do
    import_start = System.monotonic_time(:millisecond)
    import_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    Logger.metadata(import_id: import_id, image_ref: ref)

    tar_size = byte_size(tar_data)
    Logger.info("=== Starting import #{import_id} for #{ref} ===")
    Logger.info("Tar size: #{Float.round(tar_size / 1_048_576, 2)} MB")

    work_dir = Path.join( @data_dir, "imports/#{System.unique_integer([:positive])}")
    File.mkdir_p!(work_dir)

    try do
      # Step 1: Extract tar
      step_start = System.monotonic_time(:millisecond)
      Logger.info("[Step 1/5] Extracting tar archive...")
      Zypi.Store.Images.update_progress(ref, :extracting, 10)

      image_dir = case extract_tar_streaming(tar_data, Path.join(work_dir, "extracted")) do
        {:ok, dir} ->
          step_time = System.monotonic_time(:millisecond) - step_start
          Logger.info("[Step 1/5] Extraction completed in #{step_time}ms")
          dir
        {:error, reason} ->
          Logger.error("[Step 1/5] Extraction FAILED: #{inspect(reason)}")
          Zypi.Store.Images.mark_failed(ref, {:extraction_failed, reason})
          throw({:step_failed, :extraction, reason})
      end

      # Step 2: Parse OCI config
      step_start = System.monotonic_time(:millisecond)
      Logger.info("[Step 2/5] Parsing OCI config...")
      Zypi.Store.Images.update_progress(ref, :parsing_config, 20)

      oci_config = case parse_oci_config(image_dir) do
        {:ok, config} ->
          step_time = System.monotonic_time(:millisecond) - step_start
          Logger.info("[Step 2/5] Config parsed in #{step_time}ms")
          config
        {:error, reason} ->
          Logger.error("[Step 2/5] Config parse FAILED: #{inspect(reason)}")
          Zypi.Store.Images.mark_failed(ref, {:config_parse_failed, reason})
          throw({:step_failed, :config_parse, reason})
      end

      container_config = extract_container_config(oci_config)
      Logger.debug("Container config: cmd=#{inspect(container_config.cmd)}, entrypoint=#{inspect(container_config.entrypoint)}")

      # Step 3: Get docker layers
      step_start = System.monotonic_time(:millisecond)
      Logger.info("[Step 3/5] Reading layer information...")

      docker_layers = case get_docker_layers(image_dir) do
        {:ok, layers} ->
          step_time = System.monotonic_time(:millisecond) - step_start
          Logger.info("[Step 3/5] Found #{length(layers)} layers in #{step_time}ms")
          Enum.each(layers, fn l -> Logger.debug("  Layer: #{Path.basename(l)}") end)
          layers
        {:error, reason} ->
          Logger.error("[Step 3/5] Layer parse FAILED: #{inspect(reason)}")
          Zypi.Store.Images.mark_failed(ref, {:layers_parse_failed, reason})
          throw({:step_failed, :layers_parse, reason})
      end

      Zypi.Store.Images.update_progress(ref, :applying_layers, 30, %{total_layers: length(docker_layers)})

      # Step 4: Find base ext4
      step_start = System.monotonic_time(:millisecond)
      Logger.info("[Step 4/5] Locating base ext4 image...")

      base_ext4 = case find_base_ext4() do
        {:ok, path} ->
          step_time = System.monotonic_time(:millisecond) - step_start
          base_size = File.stat!(path).size
          Logger.info("[Step 4/5] Found base ext4 in #{step_time}ms: #{path} (#{div(base_size, 1_048_576)} MB)")
          path
        {:error, reason} ->
          Logger.error("[Step 4/5] Base ext4 lookup FAILED: #{inspect(reason)}")
          Zypi.Store.Images.mark_failed(ref, {:base_ext4_failed, reason})
          throw({:step_failed, :base_ext4, reason})
      end

      # Step 5: Build ext4 image
      step_start = System.monotonic_time(:millisecond)
      Logger.info("[Step 5/5] Building ext4 image (copying base + applying layers)...")

      ext4_path = case build_ext4_image(ref, base_ext4, docker_layers, Map.from_struct(container_config)) do
        {:ok, path} ->
          step_time = System.monotonic_time(:millisecond) - step_start
          Logger.info("[Step 5/5] Image built in #{step_time}ms")
          path
        {:error, reason} ->
          Logger.error("[Step 5/5] Image build FAILED: #{inspect(reason)}")
          Zypi.Store.Images.mark_failed(ref, {:build_failed, reason})
          throw({:step_failed, :build, reason})
      end

      # Final: Register image
      size_bytes = File.stat!(ext4_path).size
      Zypi.Pool.ImageStore.put_image(ref, ext4_path, Map.from_struct(container_config), size_bytes)
      Zypi.Store.Images.mark_completed(ref, ext4_path, size_bytes, Map.from_struct(container_config))

      total_time = System.monotonic_time(:millisecond) - import_start
      Logger.info("=== Import #{import_id} COMPLETE ===")
      Logger.info("Total time: #{total_time}ms, Final size: #{div(size_bytes, 1_048_576)} MB")

      {:ok, %{ref: ref, ext4_path: ext4_path, size_bytes: size_bytes, container_config: container_config}}

    catch
      {:step_failed, step, reason} ->
        total_time = System.monotonic_time(:millisecond) - import_start
        Logger.error("=== Import #{import_id} FAILED at step #{step} after #{total_time}ms ===")
        {:error, {step, reason}}
    after
      File.rm_rf!(work_dir)
      Logger.metadata(import_id: nil, image_ref: nil)
    end
  end

  defp build_ext4_image(ref, base_ext4, docker_layers, container_config) do
    layer_hash = hash_layers(docker_layers)
    cached_path = Path.join(@images_dir, "cache-#{layer_hash}.ext4")

    try do
      if File.exists?(cached_path) do
        Logger.info("Using cached image for layer hash #{layer_hash}")
        encoded = Base.url_encode64(ref, padding: false)
        ext4_path = Path.join(@images_dir, "#{encoded}.ext4")

        with {_, 0} <- System.cmd("cp", ["--reflink=auto", "--sparse=always", cached_path, ext4_path], stderr_to_stdout: true),
            :ok <- Zypi.Image.InitGenerator.inject(ext4_path, container_config) do
          {:ok, ext4_path}
        else
          {error_output, exit_code} ->
            File.rm(ext4_path)  # Try to clean up
            {:error, "cp failed with exit #{exit_code}: #{error_output}"}

          {:error, reason} ->
            File.rm(ext4_path)  # Try to clean up
            {:error, "init injection failed: #{reason}"}
        end
      else
        Logger.info("Building new image, will cache as #{layer_hash}")
        {:ok, ext4_path} = do_build_ext4_image(ref, base_ext4, docker_layers, container_config)

        # Run cache copy async - don't wait for it
        Task.Supervisor.start_child(Zypi.ImporterTasks, fn ->
          Logger.debug("Caching image as #{layer_hash}")
          System.cmd("cp", ["--reflink=auto", "--sparse=always", ext4_path, cached_path], stderr_to_stdout: true)
          Logger.debug("Cache complete for #{layer_hash}")
        end)

        {:ok, ext4_path}
      end
    rescue
      error ->
        {:error, "unexpected error: #{inspect(error)}"}
    end
  end

  defp hash_layers(docker_layers) do
    layer_info = docker_layers
    |> Enum.map(fn layer_path ->
      basename = Path.basename(layer_path)
      size = case File.stat(layer_path) do
        {:ok, %{size: size}} -> size
        {:error, _} -> 0
      end
      "#{basename}:#{size}"
    end)
    |> Enum.sort()
    |> Enum.join("|")

    hash = :crypto.hash(:sha256, layer_info)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)

    Logger.debug("Layer hash: #{hash} from #{length(docker_layers)} layers")
    hash
  end

  defp do_build_ext4_image(ref, base_ext4, docker_layers, container_config) do
    encoded = Base.url_encode64(ref, padding: false)
    ext4_path = Path.join( @images_dir, "#{encoded}.ext4")

    # Copy base image
    copy_start = System.monotonic_time(:millisecond)
    Logger.info("Copying base image (reflink if supported)...")
    {output, exit_code} = System.cmd("cp", ["--reflink=auto", "--sparse=always", base_ext4, ext4_path], stderr_to_stdout: true)
    copy_time = System.monotonic_time(:millisecond) - copy_start

    if exit_code != 0 do
      Logger.error("Base copy failed: #{output}")
      throw({:error, {:base_copy_failed, exit_code, output}})
    end

    Logger.info("Base image copied in #{copy_time}ms")

    total_layers = length(docker_layers)
    Logger.info("Applying #{total_layers} layers with overlaybd-apply...")

    layers_start = System.monotonic_time(:millisecond)

    result = docker_layers
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {layer, index}, :ok ->
      layer_start = System.monotonic_time(:millisecond)
      layer_name = Path.basename(layer)
      layer_size = File.stat!(layer).size

      Logger.info("  Layer #{index}/#{total_layers}: #{layer_name} (#{div(layer_size, 1024)} KB)")

      case apply_layer_with_retry(layer, ext4_path) do
        :ok ->
          layer_time = System.monotonic_time(:millisecond) - layer_start
          progress = 30 + div(60 * index, total_layers)
          Zypi.Store.Images.update_progress(ref, :applying_layers, progress, %{applied_layers: index})

          :telemetry.execute( @telemetry_prefix ++ [:layer_applied],
            %{duration_ms: layer_time, index: index, total: total_layers},
            %{ref: ref, layer: layer_name})

          Logger.info("  Layer #{index}/#{total_layers} applied in #{layer_time}ms")
          {:cont, :ok}

        {:error, _} = error ->
          Logger.error("  Layer #{index}/#{total_layers} FAILED")
          {:halt, error}
      end
    end)

    layers_time = System.monotonic_time(:millisecond) - layers_start
    Logger.info("All layers applied in #{layers_time}ms")

    case result do
      :ok ->
        # Inject init
        inject_start = System.monotonic_time(:millisecond)
        Logger.info("Injecting init script...")
        :ok = Zypi.Image.InitGenerator.inject(ext4_path, container_config)
        inject_time = System.monotonic_time(:millisecond) - inject_start
        Logger.info("Init injected in #{inject_time}ms")
        {:ok, ext4_path}

      {:error, reason} ->
        File.rm(ext4_path)
        {:error, reason}
    end
  catch
    {:error, _} = err -> err
  end



defp extract_tar_streaming(tar_data, dest) do
  File.mkdir_p!(dest)

  tar_size = byte_size(tar_data)
  start_time = System.monotonic_time(:millisecond)
  Logger.info("Starting streaming tar extraction: #{tar_size} bytes to #{dest}")

  # Create a named FIFO - this allows proper EOF signaling
  fifo_path = Path.join(System.tmp_dir!(), "zypi-tar-#{System.unique_integer([:positive])}")

  case System.cmd("mkfifo", [fifo_path], stderr_to_stdout: true) do
    {_, 0} -> :ok
    {err, code} ->
      Logger.error("Failed to create FIFO: #{err}")
      throw({:error, {:mkfifo_failed, code, err}})
  end

  Logger.debug("Created FIFO at #{fifo_path}")

  try do
    # Start tar reading from the FIFO (not stdin)
    # This way we can signal EOF by closing our write handle
    port = Port.open({:spawn_executable, "/bin/tar"}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: ["xf", fifo_path, "-C", dest]
    ])

    Logger.debug("Started tar process, port: #{inspect(port)}")

    # Write data to FIFO in a separate process
    # FIFO write blocks until a reader opens the other end
    parent = self()
    writer_ref = make_ref()

    writer_pid = spawn(fn ->
      writer_start = System.monotonic_time(:millisecond)
      Logger.debug("Writer[#{inspect(self())}]: Opening FIFO for writing...")

      try do
        # Open FIFO for writing - this blocks until tar opens read end
        {:ok, file} = File.open(fifo_path, [:write, :binary, :raw])
        open_time = System.monotonic_time(:millisecond) - writer_start
        Logger.debug("Writer: FIFO opened in #{open_time}ms, writing #{tar_size} bytes...")

        # Write in chunks for better performance and progress tracking
        chunk_size = 4_194_304  # 4MB chunks
        write_chunks(file, tar_data, chunk_size, 0, tar_size)

        # Close file - this signals EOF to tar!
        :ok = File.close(file)

        write_time = System.monotonic_time(:millisecond) - writer_start
        Logger.debug("Writer: Completed in #{write_time}ms, EOF signaled to tar")
        send(parent, {:writer_done, writer_ref, :ok})
      rescue
        e ->
          Logger.error("Writer: Failed with error: #{inspect(e)}")
          send(parent, {:writer_done, writer_ref, {:error, e}})
      end
    end)

    Logger.debug("Writer process started: #{inspect(writer_pid)}")

    # Collect any tar output while waiting
    tar_output = collect_tar_output(port, [])

    # Wait for writer to complete
    writer_result = receive do
      {:writer_done, ^writer_ref, result} ->
        Logger.debug("Writer finished with: #{inspect(result)}")
        result
    after
      120_000 ->
        Logger.error("Writer timeout after 120s")
        Process.exit(writer_pid, :kill)
        {:error, :writer_timeout}
    end

    case writer_result do
      :ok ->
        # Wait for tar to exit
        Logger.debug("Waiting for tar to exit...")
        wait_for_tar_exit(port, tar_output, start_time, dest)

      {:error, reason} ->
        Logger.error("Writer failed: #{inspect(reason)}")
        safe_port_close(port)
        {:error, {:writer_failed, reason}}
    end

  catch
    {:error, _} = err -> err
  after
    # Clean up FIFO
    case File.rm(fifo_path) do
      :ok -> Logger.debug("Cleaned up FIFO: #{fifo_path}")
      {:error, reason} -> Logger.warning("Failed to remove FIFO #{fifo_path}: #{reason}")
    end
  end
end

defp write_chunks(file, data, chunk_size, written, total) when written < total do
  remaining = total - written
  this_chunk = min(chunk_size, remaining)
  chunk = binary_part(data, written, this_chunk)

  case :file.write(file, chunk) do
    :ok ->
      new_written = written + this_chunk
      if rem(new_written, 16_777_216) < chunk_size do  # Log every ~16MB
        Logger.debug("Writer: #{new_written}/#{total} bytes (#{div(new_written * 100, total)}%)")
      end
      write_chunks(file, data, chunk_size, new_written, total)
    {:error, reason} ->
      throw({:write_error, reason})
  end
end

defp write_chunks(_file, _data, _chunk_size, written, total) when written >= total do
  :ok
end

defp collect_tar_output(port, acc) do
  receive do
    {^port, {:data, data}} ->
      Logger.debug("Tar output: #{String.trim(data)}")
      collect_tar_output(port, [data | acc])
  after
    0 -> Enum.reverse(acc) |> Enum.join()
  end
end

defp wait_for_tar_exit(port, existing_output, start_time, dest) do
  receive do
    {^port, {:data, data}} ->
      Logger.debug("Tar output: #{String.trim(data)}")
      wait_for_tar_exit(port, existing_output <> data, start_time, dest)

    {^port, {:exit_status, 0}} ->
      total_time = System.monotonic_time(:millisecond) - start_time
      Logger.info("Tar extraction completed successfully in #{total_time}ms")
      {:ok, dest}

    {^port, {:exit_status, code}} ->
      total_time = System.monotonic_time(:millisecond) - start_time
      Logger.error("Tar extraction failed after #{total_time}ms with exit code #{code}")
      Logger.error("Tar output: #{existing_output}")
      {:error, {:tar_extract_failed, code, existing_output}}

  after
    60_000 ->
      Logger.error("Tar process timeout - no exit status after 60s")
      Logger.error("Tar output so far: #{existing_output}")
      safe_port_close(port)
      {:error, :tar_timeout}
  end
end

defp safe_port_close(port) do
  try do
    if Port.info(port) != nil do
      Port.close(port)
    end
  catch
    _, _ -> :ok
  end
end

  defp parse_oci_config(image_dir) do
    manifest_path = Path.join(image_dir, "manifest.json")
    with {:ok, data} <- File.read(manifest_path),
         [manifest | _] <- Jason.decode!(data),
         config_file when not is_nil(config_file) <- manifest["Config"],
         {:ok, config_data} <- File.read(Path.join(image_dir, config_file)) do
      {:ok, Jason.decode!(config_data)}
    else
      _ -> {:error, :config_parse_failed}
    end
  end

  defp extract_container_config(oci_config) do
    cfg = oci_config["config"] || %{}
    %ContainerConfig{
      cmd: cfg["Cmd"],
      entrypoint: cfg["Entrypoint"],
      env: cfg["Env"] || [],
      workdir: cfg["WorkingDir"] || "/",
      user: cfg["User"] || "root"
    }
  end

  defp get_docker_layers(image_dir) do
    manifest_path = Path.join(image_dir, "manifest.json")
    with {:ok, data} <- File.read(manifest_path),
         [manifest | _] <- Jason.decode!(data) do
      layers = Enum.map(manifest["Layers"] || [], &Path.join(image_dir, &1))
      {:ok, layers}
    else
      _ -> {:error, :layers_parse_failed}
    end
  end

  defp find_base_ext4 do
    case :persistent_term.get( @base_ext4_cache_key, {nil, nil}) do
      {cached_path, cached_mtime} when not is_nil(cached_path) ->
        case File.stat( @base_dir) do
          {:ok, %{mtime: ^cached_mtime}} ->
            if File.exists?(cached_path) do
              {:ok, cached_path}
            else
              find_and_cache_base_ext4()
            end
          _ ->
            find_and_cache_base_ext4()
        end
      _ ->
        find_and_cache_base_ext4()
    end
  end

  defp find_and_cache_base_ext4 do
    case File.ls( @base_dir) do
      {:ok, files} ->
        case Enum.find(files, &String.ends_with?(&1, ".ext4")) do
          nil ->
            {:error, :no_base_ext4}
          file ->
            path = Path.join( @base_dir, file)
            case File.stat( @base_dir) do
              {:ok, %{mtime: mtime}} ->
                :persistent_term.put( @base_ext4_cache_key, {path, mtime})
                Logger.debug("Cached base ext4 path: #{path}")
              _ ->
                :ok
            end
            {:ok, path}
        end
      {:error, reason} ->
        {:error, {:base_dir_error, reason}}
    end
  end

  # defp inject_init(ext4_path, container_config) do
  #   mount_point = "/tmp/zypi-mount-#{System.unique_integer([:positive])}"
  #   File.mkdir_p!(mount_point)

  #   try do
  #     {_, 0} = System.cmd("mount", ["-o", "loop", ext4_path, mount_point], stderr_to_stdout: true)

  #     # Create directories
  #     Enum.each(~w[sbin etc/zypi root/.ssh], fn dir ->
  #       File.mkdir_p!(Path.join(mount_point, dir))
  #     end)

  #     # Nuke Ubuntu's dynamic MOTD system
  #     File.write!(Path.join(mount_point, "etc/legal"), "")
  #     update_motd_dir = Path.join(mount_point, "etc/update-motd.d")
  #     File.rm_rf(update_motd_dir)
  #     File.mkdir_p!(update_motd_dir)

  #     # Write init script
  #     init_script = generate_init_script(container_config)
  #     init_path = Path.join(mount_point, "sbin/zypi-init")
  #     File.write!(init_path, init_script)
  #     File.chmod!(init_path, 0o755)

  #     # Symlink /sbin/init -> zypi-init
  #     sbin_init = Path.join(mount_point, "sbin/init")
  #     File.rm(sbin_init)
  #     File.ln_s!("zypi-init", sbin_init)

  #     # Copy SSH authorized keys
  #     ssh_key_path = Application.get_env(:zypi, :ssh_key_path)
  #     if ssh_key_path && File.exists?("#{ssh_key_path}.pub") do
  #       pub_key = File.read!("#{ssh_key_path}.pub")
  #       auth_keys = Path.join(mount_point, "root/.ssh/authorized_keys")
  #       File.write!(auth_keys, pub_key)
  #       File.chmod!(auth_keys, 0o600)
  #     end

  #     # Write container config
  #     config_path = Path.join(mount_point, "etc/zypi/config.json")
  #     File.write!(config_path, Jason.encode!(container_config))

  #     :ok
  #   after
  #     System.cmd("umount", [mount_point], stderr_to_stdout: true)
  #     File.rmdir(mount_point)
  #   end
  # end

  # defp generate_init_script(config) do
  #   entrypoint = Map.get(config, :entrypoint) || []
  #   cmd = Map.get(config, :cmd) || []
  #   env = Map.get(config, :env) || []
  #   workdir = Map.get(config, :workdir) || "/"

  #   env_exports = env |> Enum.map(&"export #{&1}") |> Enum.join("\n")

  #   main_cmd = case {entrypoint, cmd} do
  #     {[], []} -> nil
  #     {[], c} -> shell_escape(c)
  #     {e, []} -> shell_escape(e)
  #     {e, c} -> shell_escape(e ++ c)
  #   end

  #   main_section = if main_cmd, do: "cd #{workdir}\n(#{main_cmd}) &", else: "cd #{workdir}"

  #   motd_banner = ~S"""
  #   ╔═══════════════════════════════════════════════════════════════╗
  #   ║                                                               ║
  #   ║   ███████╗██╗   ██╗██████╗ ██╗                                ║
  #   ║   ╚══███╔╝╚██╗ ██╔╝██╔══██╗██║                                ║
  #   ║     ███╔╝  ╚████╔╝ ██████╔╝██║                                ║
  #   ║    ███╔╝    ╚██╔╝  ██╔═══╝ ██║                                ║
  #   ║   ███████╗   ██║   ██║     ██║                                ║
  #   ║   ╚══════╝   ╚═╝   ╚═╝     ╚═╝                                ║
  #   ║                                                               ║
  #   ║   ⚡ Firecracker microVM · Sub-second boot · CoW snapshots    ║
  #   ║                                                               ║
  #   ╚═══════════════════════════════════════════════════════════════╝
  #   """

  #   """
  #   #!/bin/sh
  #   touch /var/log/lastlog
  #   mount -t proc proc /proc 2>/dev/null
  #   mount -t sysfs sysfs /sys 2>/dev/null
  #   mount -t devtmpfs devtmpfs /dev 2>/dev/null
  #   mkdir -p /dev/pts /dev/shm /run/sshd /var/log
  #   mount -t devpts devpts /dev/pts 2>/dev/null
  #   mount -t tmpfs tmpfs /run 2>/dev/null
  #   ip link set lo up 2>/dev/null
  #   ip link set eth0 up 2>/dev/null
  #   export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  #   export HOME=/root
  #   rm -rf /etc/update-motd.d/* 2>/dev/null
  #   cat > /etc/motd << 'MOTD'
  #   #{motd_banner}
  #   MOTD

  #   #{env_exports}
  #   if [ -x /usr/sbin/sshd ]; then
  #     mkdir -p /run/sshd
  #     [ ! -f /etc/ssh/ssh_host_rsa_key ] && ssh-keygen -A 2>/dev/null
  #     /usr/sbin/sshd -D -e &
  #   fi
  #   #{main_section}
  #   while true; do sleep 60; done
  #   """
  # end

  # defp shell_escape(args) when is_list(args) do
  #   Enum.map_join(args, " ", &("'" <> String.replace(&1, "'", "'\\''") <> "'"))
  # end
end
