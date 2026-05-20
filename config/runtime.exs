import Config

# Runtime configuration — evaluated after code compilation, before app start.
# This is the right place for environment-specific overrides that must take effect
# before GenServer init() runs.

if config_env() == :test do
  config :zypi,
    data_dir: System.get_env("ZYPI_TEST_DATA_DIR", "/tmp/zypi-test"),
    vm_pool: [min_warm: 0, max_warm: 0, max_total: 0],
    ssh_key_path: nil

  config :logger, level: :warn
end
