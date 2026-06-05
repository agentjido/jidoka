defmodule JidokaExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :jidoka_example,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {JidokaExample.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:jidoka, path: ".."},
      {:bandit, "~> 1.6"},
      {:dotenvy, "~> 1.1"},
      {:jason, "~> 1.4"},
      {:jido_action, github: "agentjido/jido_action", branch: "main", override: true},
      {:mdex, "~> 0.12.2"},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
