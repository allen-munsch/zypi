import Config

# Test configuration — uses temp directory to avoid root requirements
config :zypi,
  data_dir: System.get_env("ZYPI_TEST_DATA_DIR", "/tmp/zypi-test"),
  kernel_path: System.get_env("ZYPI_KERNEL_PATH", "/opt/zypi/kernel/vmlinux"),
  api_port: String.to_integer(System.get_env("ZYPI_API_PORT", "4001")),
  pool: [
    ip_subnet: {10, 0, 0, 0},
    ip_pool_size: 254
  ],
  vm_pool: [
    min_warm: 0,
    max_warm: 3,
    max_total: 10
  ],
  ssh_key_path: nil

config :logger, level: :warn
