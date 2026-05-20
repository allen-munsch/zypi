defmodule Zypi.Runtime do
  @moduledoc """
  Runtime dispatcher that selects the appropriate backend for the current platform.
  
  ## Platform Detection
  
  - Linux with KVM → Firecracker
  - macOS → Virtualization.framework or QEMU
  - Windows → WSL2+Firecracker or Hyper-V
  
  ## Configuration
  
  Override auto-detection:
  
      config :zypi, :runtime, Zypi.Runtime.QEMU
  
  Or set preferred order:
  
      config :zypi, :runtime_preference, [:firecracker, :virtframework, :hyperv, :qemu]
  """

  require Logger

  @behaviour Zypi.Runtime.Behaviour

  # Runtime modules in preference order per platform
  @linux_runtimes [
    Zypi.Runtime.Firecracker,
    Zypi.Runtime.QEMU
  ]

  @macos_runtimes [
    Zypi.Runtime.VirtFramework,
    Zypi.Runtime.QEMU
  ]

  @windows_runtimes [
    Zypi.Runtime.WSL2,
    Zypi.Runtime.HyperV,
    Zypi.Runtime.QEMU
  ]

  @doc """
  Get the current runtime module.
  """
  def current do
    case Application.get_env(:zypi, :runtime) do
      nil -> detect_runtime()
      module when is_atom(module) -> module
    end
  end

  @doc """
  Detect the best available runtime for this platform.
  """
  def detect_runtime do
    runtimes = case :os.type() do
      {:unix, :linux} -> @linux_runtimes
      {:unix, :darwin} -> @macos_runtimes
      {:win32, _} -> @windows_runtimes
      _ -> []
    end

    # Apply user preference if configured
    runtimes = case Application.get_env(:zypi, :runtime_preference) do
      nil -> runtimes
      prefs when is_list(prefs) -> sort_by_preference(runtimes, prefs)
    end

    case Enum.find(runtimes, & &1.available?()) do
      nil ->
        Logger.error("No compatible runtime found for this platform")
        raise "No compatible VM runtime available"
      runtime ->
        Logger.info("Selected runtime: #{runtime.name()}")
        runtime
    end
  end

  defp sort_by_preference(runtimes, prefs) do
    pref_map = prefs
    |> Enum.with_index()
    |> Map.new(fn {name, idx} -> {name, idx} end)

    Enum.sort_by(runtimes, fn mod ->
      name = mod.name() |> String.downcase() |> String.to_atom()
      Map.get(pref_map, name, 999)
    end)
  end

  @doc """
  Get information about available runtimes.
  """
  def available_runtimes do
    all = @linux_runtimes ++ @macos_runtimes ++ @windows_runtimes
    |> Enum.uniq()

    Enum.map(all, fn mod ->
      %{ 
        module: mod,
        name: mod.name(),
        available: mod.available?()
      }
    end)
  end

  @doc """
  Get current platform info.
  """
  def platform_info do
    {family, name} = :os.type()
    %{ 
      os_family: family,
      os_name: name,
      arch: to_string(:erlang.system_info(:system_architecture)),
      runtime: current().name()
    }
  end

  # Delegate all behaviour callbacks to current runtime

  @impl true
  def start(container), do: current().start(container)

  @impl true
  def stop(container), do: current().stop(container)

  @impl true
  def exec(container_id, cmd, opts \\ []), do: current().exec(container_id, cmd, opts)

  @impl true
  def health(container_id), do: current().health(container_id)

  @impl true
  def cleanup(container_id), do: current().cleanup(container_id)

  @impl true
  def available?, do: current().available?()

  @impl true
  def name, do: "Zypi.Runtime Dispatcher"

  @impl true
  def setup_network(container_id, ip), do: current().setup_network(container_id, ip)

  @impl true
  def teardown_network(container_id, state), do: current().teardown_network(container_id, state)
end
