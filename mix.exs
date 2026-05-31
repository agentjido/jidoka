defmodule Jidoka.MixProject do
  use Mix.Project

  def project do
    [
      app: :jidoka,
      version: "1.0.0-beta.1",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      dialyzer: dialyzer(),
      test_coverage: [
        ignore_modules: [
          ~r/^Jidoka\.Agent\.Dsl(\.|$)/,
          ~r/^Jidoka\.Agent\.Verifiers\./,
          ~r/^Jidoka\.IntegrationSupport\./
        ],
        summary: [threshold: 80]
      ],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Jidoka.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:dotenvy, "~> 1.1"},
      {:ash_jido, "~> 1.0"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:jason, "~> 1.4"},
      {:jido, "~> 2.3"},
      {:jido_browser, "~> 2.1"},
      {:req_llm, "~> 1.12"},
      {:runic, "~> 0.1.0-alpha.7"},
      {:splode, "~> 0.3.0"},
      {:sourceror, "~> 1.7", only: [:dev, :test], runtime: false},
      {:spark, "~> 2.6"},
      {:yaml_elixir, "~> 2.12"},
      {:zoi, "~> 0.18"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp dialyzer do
    [
      plt_add_apps: [:llm_db, :mix]
    ]
  end
end
