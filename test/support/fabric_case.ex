defmodule Zypi.FabricCase do
  @moduledoc """
  Test case template for fabric integration tests.

  Usage:
      use Zypi.FabricCase, tags: [:fabric, :integration]

  Skips tests gracefully when Zypi prerequisites aren't met.
  """

  use ExUnit.CaseTemplate

  using opts do
    tags = Keyword.get(opts, :tags, [])

    quote do
      @moduletag unquote(tags)

      import Zypi.FabricCase

      setup do
        Zypi.FabricCase.ensure_prerequisites!()
        :ok
      end
    end
  end

  @doc "Raise if prerequisites are missing. Called in setup block."
  def ensure_prerequisites! do
    errors = []

    errors = unless File.exists?("/dev/kvm"), do: ["KVM not available" | errors], else: errors

    fc_path = System.find_executable("firecracker")
    errors = unless fc_path, do: ["Firecracker binary not found" | errors], else: errors

    kernel_path = Application.get_env(:zypi, :kernel_path, "/opt/zypi/kernel/vmlinux")
    errors = unless File.exists?(kernel_path), do: ["Kernel not found at #{kernel_path}" | errors], else: errors

    rootfs_path = "/opt/zypi/rootfs/ubuntu-24.04.ext4"
    errors = unless File.exists?(rootfs_path), do: ["Base rootfs not found at #{rootfs_path}" | errors], else: errors

    unless errors == [] do
      missing = Enum.join(Enum.reverse(errors), "; ")
      raise """
      Fabric integration tests require a full Zypi environment:

      Missing prerequisites:
      #{Enum.map_join(Enum.reverse(errors), "\n", &"  - #{&1}")}

      Run with: mix test --exclude fabric
      Or set up Zypi via: docker compose up zypi
      """
    end

    :ok
  end

  @doc "Check if fabric is ready without raising."
  def fabric_ready? do
    try do
      ensure_prerequisites!()
      true
    rescue
      _ -> false
    end
  end

  @doc "Wait for Zypi health endpoint to respond."
  def wait_for_zypi_ready(timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.iterate(1, &(&1 + 1))
    |> Enum.reduce_while(:timeout, fn attempt, _ ->
      if System.monotonic_time(:millisecond) >= deadline do
        {:halt, {:error, :timeout}}
      else
        case :gen_tcp.connect(~c"localhost", 4000, [], 500) do
          {:ok, sock} ->
            :gen_tcp.close(sock)
            {:halt, {:ok, attempt}}

          {:error, _} ->
            Process.sleep(500)
            {:cont, :retry}
        end
      end
    end)
  end

  @doc "Wait for VMPool to have warm VMs."
  def wait_for_warm_vms(count, timeout_ms \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.iterate(1, &(&1 + 1))
    |> Enum.reduce_while(:timeout, fn _attempt, _ ->
      if System.monotonic_time(:millisecond) >= deadline do
        {:halt, {:error, :timeout}}
      else
        stats = Zypi.Pool.VMPool.stats()
        if stats.warm >= count do
          {:halt, {:ok, stats}}
        else
          Process.sleep(1000)
          {:cont, :retry}
        end
      end
    end)
  end
end
