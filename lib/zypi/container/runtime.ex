defmodule Zypi.Container.Runtime do
  @moduledoc """
  Legacy runtime module - delegates to Zypi.Runtime dispatcher.
  Kept for backwards compatibility.
  """

  defdelegate start(container), to: Zypi.Runtime
  defdelegate stop(container), to: Zypi.Runtime
  defdelegate cleanup_rootfs(container_id), to: Zypi.Runtime, as: :cleanup
end
