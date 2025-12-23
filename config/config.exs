import Config

config :zypi,
  data_dir: System.get_env("ZYPI_DATA_DIR", "/var/lib/zypi"),
  kernel_path: System.get_env("ZYPI_KERNEL_PATH", "/opt/zypi/kernel/vmlinux"),
  api_port: String.to_integer(System.get_env("ZYPI_API_PORT", "4000")),
  pool: [
    ip_subnet: {10, 0, 0, 0},
    ip_pool_size: 254
  ]

log_level =
  case System.get_env("ZYPI_LOG_LEVEL", "info") do
    "debug" -> :debug
    "info" -> :info
    "warn" -> :warn
    "error" -> :error
    _other -> :info  # default fallback
  end

config :logger,
  level: log_level,
  format: "$time $metadata[$level] $message\n"

# Platform-specific configuration
case :os.type() do
  {:unix, :linux} ->
    config :zypi,
      data_dir: "/var/lib/zypi",
      kernel_path: "/opt/zypi/kernel/vmlinux",
      runtime_preference: [:firecracker, :qemu]
      
  {:unix, :darwin} ->
    config :zypi,
      data_dir: Path.expand("~/.zypi"),
      kernel_path: Path.expand("~/.zypi/kernel/Image.gz"),
      runtime_preference: [:virtframework, :qemu],
      virt_helper_path: "/usr/local/bin/zypi-virt"
      
  {:win32, _} ->
    config :zypi,
      data_dir: "C:\\ProgramData\\Zypi",
      kernel_path: "C:\\ProgramData\\Zypi\\kernel\\vmlinux",
      runtime_preference: [:wsl2, :hyperv, :qemu],
      wsl_distro: "Ubuntu"
      
  _ ->
    config :zypi,
      data_dir: "/tmp/zypi",
      runtime_preference: [:qemu]
end