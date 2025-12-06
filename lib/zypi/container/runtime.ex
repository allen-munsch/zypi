defmodule Zypi.Container.Runtime do
  @moduledoc """
  Runtime dispatcher. Delegates to Firecracker runtime.
  """

  defdelegate start(container), to: Zypi.Container.RuntimeFirecracker
  defdelegate stop(container), to: Zypi.Container.RuntimeFirecracker
  defdelegate cleanup_rootfs(container_id), to: Zypi.Container.RuntimeFirecracker
end