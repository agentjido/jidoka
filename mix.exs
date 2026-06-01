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
      description: description(),
      package: package(),
      source_url: source_url(),
      homepage_url: source_url(),
      docs: docs(),
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
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:jason, "~> 1.4"},
      {:jido, "~> 2.3"},
      {:jido_ai, "~> 2.2"},
      {:jido_browser, "~> 2.1"},
      {:jido_memory, "~> 1.0"},
      {:jido_mcp, "~> 1.0"},
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

  defp description do
    "A thin, data-driven agent harness for the Jido ecosystem with a Spark DSL and Runic turn spine."
  end

  defp source_url, do: "https://github.com/mikehostetler/jidoka-v2"

  defp package do
    [
      files: [
        "lib",
        "guides",
        "livebook",
        ".formatter.exs",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => source_url()
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v1.0.0-beta.1",
      source_url: source_url(),
      extras:
        [
          "README.md",
          "CHANGELOG.md",
          "LICENSE"
        ] ++ Path.wildcard("guides/*.{md,livemd}") ++ Path.wildcard("livebook/*.livemd")
    ]
  end
end
