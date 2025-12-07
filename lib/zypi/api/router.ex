defmodule Zypi.API.Router do
  use Plug.Router
  require Logger

  alias Zypi.Container.Manager
  alias Zypi.Store.Containers
  alias Zypi.Pool.ImageStore
  alias Zypi.API.ConsoleSocket
  alias Zypi.Store.Images, as: StoreImages
  alias Zypi.Image.Importer, as: ImageImporter

  defmodule Zypi.API.RequestTimer do
    @behaviour Plug
    
    def init(opts), do: opts
    
    def call(conn, _opts) do
      start_time = System.monotonic_time()
      
      Plug.Conn.register_before_send(conn, fn conn ->
        duration = System.monotonic_time() - start_time
        duration_ms = System.convert_time_unit(duration, :native, :millisecond)
        
        :telemetry.execute(
          [:zypi, :api, :request],
          %{duration_ms: duration_ms},
          %{
            path: conn.request_path,
            method: conn.method,
            status: conn.status
          }
        )
        
        # Add timing header
        Plug.Conn.put_resp_header(conn, "x-request-time-ms", to_string(duration_ms))
      end)
    end
  end

  plug Plug.Logger
  plug Zypi.API.RequestTimer  # Add this line
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["application/json", "application/octet-stream", "application/x-tar", "application/gzip", "application/x-gzip"]
  plug :dispatch

  get "/health" do
    send_json(conn, 200, %{status: "ok", timestamp: DateTime.utc_now()})
  end

  get "/status" do
  status = %{
    containers: Containers.count_by_status(),
    images: length(ImageStore.list_images())
  }
  send_json(conn, 200, status)
end

  get "/images" do
  send_json(conn, 200, %{images: ImageStore.list_images()})
end

get "/images/:ref/status" do
  case StoreImages.get(ref) do
    {:ok, image} ->
      response = %{
        ref: image.ref,
        status: image.status,
        progress: image.progress || 0,
        current_step: image.current_step,
        total_layers: image.total_layers || 0,
        applied_layers: image.applied_layers || 0,
        size_bytes: image.size_bytes,
        error_message: image.error_message,
        started_at: image.started_at && DateTime.to_iso8601(image.started_at),
        completed_at: image.completed_at && DateTime.to_iso8601(image.completed_at)
      }
      send_json(conn, 200, response)
    {:error, :not_found} ->
      send_json(conn, 404, %{error: "not_found"})
  end
end

get "/images/importing" do
  active_imports = StoreImages.list()
  |> Enum.filter(fn image -> 
    image.status in [:queued, :importing, :extracting, :applying_layers, :injecting_init]
  end)
  |> Enum.map(fn image ->
    %{
      ref: image.ref,
      status: image.status,
      progress: image.progress || 0,
      current_step: image.current_step,
      applied_layers: image.applied_layers || 0,
      total_layers: image.total_layers || 0,
      started_at: image.pulled_at && DateTime.to_iso8601(image.pulled_at)
    }
  end)
  
  send_json(conn, 200, %{imports: active_imports, count: length(active_imports)})
end

    post "/images/:ref/import" do
  content_type = List.first(Plug.Conn.get_req_header(conn, "content-type") || [])
  is_binary = content_type && (String.starts_with?(content_type, "application/octet-stream") || content_type == "application/x-tar" || String.contains?(content_type, "tar"))

  if is_binary do
    temp_path = Path.join(System.tmp_dir!(), "import-#{:crypto.strong_rand_bytes(8) |> Base.encode16()}.tar")
    
    try do
      case stream_body_to_file(conn, temp_path) do
        {:ok, conn, bytes_read} ->
          Logger.info("Streamed #{bytes_read} bytes for #{ref}")
          tar_data = File.read!(temp_path)
          
          case ImageImporter.import_tar(ref, tar_data) do
            {:ok, :accepted, ref} ->
              send_json(conn, 202, %{status: "accepted", ref: ref})
            {:error, reason} ->
              send_json(conn, 500, %{error: inspect(reason)})
          end
          
        {:error, :body_too_large} ->
          send_json(conn, 413, %{error: "Payload too large"})
          
        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    after
      File.rm(temp_path)
    end
  else
    send_json(conn, 415, %{error: "Unsupported Media Type"})
  end
end


  delete "/images/:ref" do
  case ImageStore.delete_image(ref) do
    :ok -> send_json(conn, 200, %{status: "deleted"})
    {:error, :not_found} -> send_json(conn, 404, %{error: "not_found"})
  end
end

  get "/containers" do
    send_json(conn, 200, %{containers: Manager.list() |> Enum.map(&container_json/1)})
  end

  get "/containers/:id" do
    case Containers.get(id) do
      {:ok, c} -> send_json(conn, 200, container_json(c))
      {:error, :not_found} -> send_json(conn, 404, %{error: "not_found"})
    end
  end

  get "/containers/:id/console_port" do
    if Containers.get(id) do
      send_json(conn, 200, %{port: ConsoleSocket.get_port()})
    else
      send_json(conn, 404, %{error: "not_found"})
    end
  end

  get "/containers/:id/shell_info" do
    case Manager.get_shell_info(id) do
      {:ok, info} ->
        send_json(conn, 200, info)

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "not_found"})

      {:error, {:not_running, status}} ->
        send_json(conn, 400, %{
          error: "container_not_running",
          status: to_string(status),
          message: "Container must be running to access shell"
        })

      {:error, :ssh_not_configured} ->
        send_json(conn, 500, %{
          error: "ssh_not_configured",
          message: "SSH key not found. Shell access unavailable."
        })
    end
  end

  get "/containers/:id/ssh_ready" do
    ready = Manager.ssh_ready?(id)
    send_json(conn, 200, %{ready: ready})
  end

  post "/containers" do
    Logger.info("API: POST /containers - #{inspect(conn.body_params)}")
    params = %{
      id: conn.body_params["id"],
      image: conn.body_params["image"],
      resources: conn.body_params["resources"],
      metadata: %{cmd: parse_cmd(conn.body_params["cmd"])}
    } |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()

    case Manager.create(params) do
      {:ok, c} -> send_json(conn, 201, container_json(c))
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/containers/:id/start" do
    case Manager.start(id) do
      {:ok, _} -> send_json(conn, 200, %{status: "started"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/containers/:id/stop" do
    case Manager.stop(id) do
      {:ok, _} -> send_json(conn, 200, %{status: "stopped"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  delete "/containers/:id" do
    case Manager.destroy(id) do
      {:ok, _} -> send_json(conn, 200, %{status: "destroyed"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/containers/:id/logs" do
    case Manager.get_output(id) do
      {:ok, output} -> send_json(conn, 200, %{logs: output})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/containers/:id/attach" do
    case Containers.get(id) do
      {:ok, %{status: status}} when status in [:running, :exited] ->
        conn = conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("connection", "keep-alive")
        |> send_chunked(200)
        Manager.subscribe(id)
        {:ok, output} = Manager.get_output(id)
        if output != "", do: chunk(conn, "data: #{Base.encode64(output)}\n\n")
        stream_output(conn, id)
      {:ok, _} -> send_json(conn, 400, %{error: "container_not_running"})
      {:error, :not_found} -> send_json(conn, 404, %{error: "not_found"})
    end
  end

  defp stream_body_to_file(conn, file_path, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, 1_048_576)  # 1MB chunks
    max_size = Keyword.get(opts, :max_size, 500_000_000)    # 500MB max
    
    File.open!(file_path, [:write, :binary], fn file ->
      stream_chunks(conn, file, 0, chunk_size, max_size)
    end)
  end

  defp stream_chunks(conn, file, total_read, chunk_size, max_size) when total_read < max_size do
    case Plug.Conn.read_body(conn, length: chunk_size, read_length: chunk_size) do
      {:ok, data, conn} ->
        IO.binwrite(file, data)
        {:ok, conn, total_read + byte_size(data)}
        
      {:more, data, conn} ->
        IO.binwrite(file, data)
        new_total = total_read + byte_size(data)
        if new_total >= max_size do
          {:error, :body_too_large}
        else
          stream_chunks(conn, file, new_total, chunk_size, max_size)
        end
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_chunks(_conn, _file, total_read, _chunk_size, max_size) when total_read >= max_size do
    {:error, :body_too_large}
  end

  match _ do
    send_json(conn, 404, %{error: "not_found"})
  end

  defp stream_output(conn, container_id) do
    receive do
      {:container_output, ^container_id, data} ->
        case chunk(conn, "data: #{Base.encode64(data)}\n\n") do
          {:ok, conn} -> stream_output(conn, container_id)
          {:error, _} -> Manager.unsubscribe(container_id)
        end
    after
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream_output(conn, container_id)
          {:error, _} -> Manager.unsubscribe(container_id)
        end
    end
  end

  defp send_json(conn, status, data) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(data))
  end

  defp container_json(c) do
    %{id: c.id, image: c.image, status: c.status, ip: format_ip(c.ip), rootfs: c.rootfs,
      created_at: c.created_at && DateTime.to_iso8601(c.created_at),
      started_at: c.started_at && DateTime.to_iso8601(c.started_at)}
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(nil), do: nil

  defp parse_cmd(nil), do: nil
  defp parse_cmd(cmd) when is_list(cmd), do: cmd
  defp parse_cmd(cmd) when is_binary(cmd), do: ["/bin/sh", "-c", cmd]
end
