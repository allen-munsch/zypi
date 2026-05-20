defmodule Zypi.Telemetry do
  @moduledoc """
  Telemetry event handlers for Zypi metrics and observability.
  """
  require Logger

  @events [
    [:zypi, :import, :start],
    [:zypi, :import, :stop],
    [:zypi, :import, :layer_applied],
    [:zypi, :import, :exception],
    [:zypi, :api, :request]
  ]

  def setup do
    :telemetry.attach_many(
      "zypi-telemetry-handler",
      @events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event([:zypi, :import, :start], measurements, metadata, _config) do
    Logger.info("[METRICS] import.start",
      ref: metadata.ref,
      size_bytes: metadata.size_bytes,
      system_time: measurements.system_time
    )
  end

  def handle_event([:zypi, :import, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    Logger.info("[METRICS] import.stop",
      ref: metadata.ref,
      status: metadata.status,
      duration_ms: duration_ms
    )
  end

  def handle_event([:zypi, :import, :layer_applied], measurements, metadata, _config) do
    Logger.info("[METRICS] import.layer_applied",
      ref: metadata.ref,
      layer: metadata.layer,
      index: measurements.index,
      total: measurements.total,
      duration_ms: measurements.duration_ms
    )
  end

  def handle_event([:zypi, :import, :exception], _measurements, metadata, _config) do
    Logger.error("[METRICS] import.exception",
      ref: metadata.ref,
      kind: metadata.kind,
      reason: inspect(metadata.reason)
    )
  end

  def handle_event([:zypi, :api, :request], measurements, metadata, _config) do
    Logger.info("[METRICS] api.request",
      path: metadata.path,
      method: metadata.method,
      status: metadata.status,
      duration_ms: measurements.duration_ms
    )
  end
end
