defmodule Zypi.Runtime.Behaviour do
  @moduledoc """
  Behaviour defining the interface for VM runtime backends.
  
  Each platform implements this behaviour:
  - Linux: Firecracker
  - macOS: Virtualization.framework or QEMU
  - Windows: WSL2+Firecracker or Hyper-V
  """

  @type container_id :: String.t()
  @type ip_address :: {byte(), byte(), byte(), byte()} | String.t()
  
  @type container :: %{
    required(:id) => container_id(),
    required(:image) => String.t(),
    required(:rootfs) => String.t(),
    required(:ip) => ip_address(),
    optional(:resources) => %{
      cpu: pos_integer(),
      memory_mb: pos_integer()
    }
  }

  @type vm_state :: %{
    required(:socket_path) => String.t() | nil,
    required(:pid) => port() | pid() | reference() | nil,
    optional(:tap_device) => String.t(),
    optional(:container_ip) => ip_address()
  }

  @type exec_result :: %{
    exit_code: integer(),
    stdout: String.t(),
    stderr: String.t(),
    signal: String.t() | nil,
    timed_out: boolean()
  }

  @doc """
  Start a VM for the given container configuration.
  Returns VM state that can be used for subsequent operations.
  """
  @callback start(container()) :: {:ok, vm_state()} | {:error, term()}

  @doc """
  Stop a running VM.
  """
  @callback stop(container()) :: :ok | {:error, term()}

  @doc """
  Execute a command in the VM via the guest agent.
  """
  @callback exec(container_id(), [String.t()], keyword()) :: 
    {:ok, exec_result()} | {:error, term()}

  @doc """
  Check VM/agent health.
  """
  @callback health(container_id()) :: {:ok, map()} | {:error, term()}

  @doc """
  Clean up resources (rootfs, network, etc).
  """
  @callback cleanup(container_id()) :: :ok

  @doc """
  Check if this runtime is available on the current system.
  """
  @callback available?() :: boolean()

  @doc """
  Get runtime name for logging/display.
  """
  @callback name() :: String.t()

  @doc """
  Setup networking for the VM. Platform-specific.
  """
  @callback setup_network(container_id(), ip_address()) :: 
    {:ok, map()} | {:error, term()}

  @doc """
  Teardown networking for the VM.
  """
  @callback teardown_network(container_id(), map()) :: :ok
end
