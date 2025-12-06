defmodule Zypi.Image.Device do
  @moduledoc """
  Attaches/detaches overlaybd block devices.
  No manifest fetching — expects pre-built configs.
  """

  require Logger

  def attach(config_path) do
    start = System.monotonic_time(:microsecond)

    result = case System.cmd("overlaybd-create", [config_path], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {err, code} -> {:error, {:attach_failed, code, err}}
    end

    elapsed = System.monotonic_time(:microsecond) - start
    Logger.debug("overlaybd-create took #{elapsed}µs")

    result
  end

  def detach(device_path) do
    case System.cmd("overlaybd-detach", [device_path], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {err, _} -> {:error, {:detach_failed, err}}
    end
  end
end