defmodule Zypi.MixProject do
  use Mix.Project

  def project do
    [
      app: :zypi,
      version: "0.1.0",
      elixir: "~> 1.19.3",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
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
      {:nimble_pool, "~> 1.0"}  # Resource pooling
    ]
  end
end
