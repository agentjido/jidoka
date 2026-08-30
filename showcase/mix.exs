defmodule JidokaShowcase.MixProject do
  use Mix.Project

  def project do
    [
      app: :jidoka_showcase,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {JidokaShowcase.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:jidoka, path: ".."},
      {:bandit, "~> 1.6"},
      {:dotenvy, "~> 1.1"},
      # tzdata 1.1 still selects the vulnerable Hackney 1.x line.
      {:hackney, "~> 4.7.4", override: true},
      {:jason, "~> 1.4"},
      {:jido_action, github: "agentjido/jido_action", branch: "main", override: true},
      {:jido_memory, "~> 1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:mdex, "~> 0.13.5"},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1"},
      # Jido dependencies still select older Req releases.
      {:req, "~> 0.7.1", override: true}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"] ++ example_paths()
  defp elixirc_paths(_env), do: ["lib"] ++ example_paths()

  defp example_paths do
    __DIR__
    |> Path.join("../examples/*/lib")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.sort()
  end
end
