# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

import Config

# General application configuration
config :zypi,
  ecto_repos: [],
  api_port: 4000,
  data_dir: System.get_env("ZYPI_DATA_DIR", "/var/lib/zypi"),
  pool: [
    min_devices_per_image: 2,
    max_devices_per_image: 10,
    ip_pool_size: 254,
    ip_subnet: {10, 0, 0, 0}
  ],
  thin_pool: [
    metadata_size_mb: 128,
    chunk_size_sectors: 128
  ]

# Configures the endpoint
# Don't forget to add your endpoint to your application supervision tree
# in lib/zypi/application.ex
#
# config :zypi, Zypi.Endpoint,
#   url: [host: "localhost"],
#   secret_key_base: "..."

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
