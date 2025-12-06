# defmodule Zypi.Container.RuntimeChroot do
#   @moduledoc """
#   Container runtime using Linux namespaces and chroot.
#   """
#   require Logger

#   @data_dir Application.compile_env(:zypi, :data_dir, "/var/lib/zypi")
#   @rootfs_dir Path.join(@data_dir, "rootfs")

#   def start(container) do
#     start_us = System.monotonic_time(:microsecond)
#     rootfs = prepare_rootfs(container)
#     cmd = container.metadata[:cmd] || ["/bin/sh"]
#     args = ["--fork", "--mount", "--uts", "--ipc", "--pid", "--", "chroot", rootfs | cmd]

#     port = Port.open({:spawn_executable, "/usr/bin/unshare"}, [
#       :binary,
#       :exit_status,
#       :use_stdio,
#       :stderr_to_stdout,
#       args: args
#     ])

#     elapsed_us = System.monotonic_time(:microsecond) - start_us
#     Logger.debug("Runtime.start took #{elapsed_us}µs")
#     {:ok, port}
#   end

#   def stop(%{pid: port}) when is_port(port) do
#     try do
#       case Port.info(port) do
#         nil -> :ok  # Already closed
#         _info ->
#           Port.close(port)
#           :ok
#       end
#     rescue
#       ArgumentError -> :ok  # Port already closed
#     end
#   end
#   def stop(_), do: :ok

#   def alive?(%{pid: port}) when is_port(port) do
#     Port.info(port) != nil
#   end
#   def alive?(_), do: false

#   def read_output(%{pid: port}, timeout \\ 0) when is_port(port) do
#     receive do
#       {^port, {:data, data}} -> {:ok, data}
#     after
#       timeout -> {:error, :timeout}
#     end
#   end

#   defp prepare_rootfs(container) do
#     rootfs = Path.join(@rootfs_dir, container.id)
#     File.mkdir_p!(rootfs)

#     case System.cmd("mount", [container.rootfs, rootfs], stderr_to_stdout: true) do
#       {_, 0} ->
#         Logger.debug("Mounted #{container.rootfs} at #{rootfs}")
#         rootfs
#       {err, code} ->
#         Logger.warning("Mount failed (#{code}): #{err}, using empty rootfs")
#         rootfs
#     end
#   end

#   def cleanup_rootfs(container_id) do
#     rootfs = Path.join(@rootfs_dir, container_id)
#     System.cmd("umount", ["-l", rootfs], stderr_to_stdout: true)
#     File.rm_rf(rootfs)
#     :ok
#   end
# end
