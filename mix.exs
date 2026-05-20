defmodule Zypi.MixProject do
  use Mix.Project

  def project do
    [
      app: :zypi,
      version: "0.1.0",
      elixir: ">= 1.19.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: Mix.compilers()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :crypto, :os_mon, :runtime_tools],
      mod: {Zypi.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:plug_cowboy, "~> 2.6"},
      {:delta_crdt, "~> 0.6"},  # For gossip state
      {:bandit, "~> 1.0"}, # Add
      {:plug, "~> 1.14"}, # Add
      {:nimble_pool, "~> 1.0"},  # Resource pooling
      # protox removed — replaced by vendored lib/zypi/protox_mini.ex
      # To regenerate v1_pb.ex from proto/zypi.proto, temporarily add:
      #   {:protox, "~> 2.0", only: :dev}
    ]
  end
end
