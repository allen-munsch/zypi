defmodule Zypi.API.Router do
  use Plug.Router
  require Logger

  alias Zypi.Container.Manager
  alias Zypi.Store.Containers
  alias Zypi.Image.{Delta, Registry}
  alias Zypi.Image.Warmer
  alias Zypi.Pool.DevicePool

  plug Plug.Logger
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["application/json", "application/octet-stream", "application/x-tar", "application/gzip", "application/x-gzip"]
  plug :dispatch

  get "/health" do
    send_json(conn, 200, %{status: "ok", timestamp: DateTime.utc_now()})
  end

  get "/status" do
    status = %{
      containers: Containers.count_by_status(),
      images: length(Registry.list()),
      pools: DevicePool.status()
    }
    send_json(conn, 200, status)
  end

  get "/images" do
    send_json(conn, 200, %{images: Registry.list()})
  end

  post "/images/:ref/push" do
    Logger.info("API: POST /images/#{ref}/push")
    case conn.body_params do
      %{"config" => config} ->
        config_str = if is_map(config), do: Jason.encode!(config), else: config
        opts = [layers: conn.body_params["layers"] || [], size_bytes: conn.body_params["size_bytes"] || 0]
        case Delta.push(ref, config_str, opts) do
          {:ok, _} -> Warmer.warm(ref); send_json(conn, 201, %{status: "pushed", ref: ref})
          {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
        end
      _ -> send_json(conn, 400, %{error: "missing config field"})
    end
  end

  post "/images/:ref/import" do
    Logger.info("API: POST /images/#{ref}/import - Starting import")

    # Debug: Log all headers
    Logger.debug("Headers: #{inspect(conn.req_headers)}")

    # Check content type
    content_type = List.first(Plug.Conn.get_req_header(conn, "content-type") || [])
    Logger.info("Content-Type header: #{inspect(content_type)}")

    # Also check for empty content-type or other variations
    Logger.info("All content-type headers: #{inspect(Plug.Conn.get_req_header(conn, "content-type"))}")

    # Check if it's octet-stream or any other binary type
    is_binary_content = content_type &&
      (String.starts_with?(content_type, "application/octet-stream") ||
       content_type == "application/x-tar" ||
       content_type == "application/gzip" ||
       String.contains?(content_type, "tar"))

    Logger.info("Is binary content? #{is_binary_content}")

    if is_binary_content do
      # Read raw body for binary content
      Logger.info("Reading binary body for import...")

      # Check content length if available
      content_length = List.first(Plug.Conn.get_req_header(conn, "content-length") || [])
      Logger.info("Content-Length: #{content_length}")

      # Try to read the body
      try do
        # Read with a reasonable limit, adjust as needed
        max_length = 100_000_000 # 100MB limit
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: max_length)

        Logger.info("Successfully read body. Body size: #{byte_size(body)} bytes")
        Logger.debug("First 100 bytes of body (hex): #{body |> binary_part(0, min(100, byte_size(body))) |> Base.encode16}")

        # Log if body is empty
        if byte_size(body) == 0 do
          Logger.error("Empty body received for import!")
        end

        case Zypi.Image.Importer.import_tar(ref, body) do
          {:ok, manifest} ->
            Logger.info("Import successful for #{ref}. Layers: #{length(manifest.layers)}, Size: #{manifest.size_bytes}")
            Zypi.Image.Warmer.warm(ref)
            send_json(conn, 201, %{
              status: "imported",
              ref: ref,
              layers: length(manifest.layers),
              size_bytes: manifest.size_bytes
            })
          {:error, reason} ->
            Logger.error("Import failed for #{ref}: #{inspect(reason)}")
            send_json(conn, 500, %{error: inspect(reason)})
        end
      rescue
        e in Plug.Conn.TooLargeError ->
          Logger.error("Body too large: #{inspect(e)}")
          send_json(conn, 413, %{error: "Payload too large"})
        e ->
          Logger.error("Error reading body: #{inspect(e)}")
          Logger.error("Stacktrace: #{inspect(__STACKTRACE__)}")
          send_json(conn, 500, %{error: "Failed to read request body: #{inspect(e)}"})
      end
    else
      Logger.warning("Unsupported Content-Type for import: #{inspect(content_type)}. Expected application/octet-stream or similar.")
      Logger.info("Request method: #{conn.method}, Path: #{conn.request_path}")
      Logger.info("Full conn before response: #{inspect(conn, limit: :infinity, pretty: true)}")

      send_json(conn, 415, %{
        error: "Unsupported Media Type",
        received: content_type,
        expected: "application/octet-stream, application/x-tar, or similar binary format",
        details: "Make sure you're sending the Docker image tar with correct Content-Type header"
      })
    end
  end

  delete "/images/:ref" do
    _result = Delta.delete(ref)
    send_json(conn, 200, %{status: "deleted"})
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
