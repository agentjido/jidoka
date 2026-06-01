defmodule Jidoka.MixProject do
  use Mix.Project

  @version "1.0.0-beta.1"
  @source_url "https://github.com/mikehostetler/jidoka-v2"
  @description "A thin, data-driven agent harness for the Jido ecosystem with a Spark DSL and Runic turn spine."

  def project do
    [
      app: :jidoka,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      dialyzer: dialyzer(),
      aliases: aliases(),
      name: "Jidoka",
      description: @description,
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      test_coverage: [
        tool: ExCoveralls,
        export: "cov",
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

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.github": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.detail": :test,
        "coveralls.lcov": :test,
        "coveralls.xml": :test,
        "coveralls.cobertura": :test
      ]
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
      {:ash_jido, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false},
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

  defp package do
    [
      files: [
        "lib",
        "guides",
        "livebook",
        ".formatter.exs",
        "coveralls.json",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "usage-rules.md",
        "LICENSE"
      ],
      maintainers: ["Mike Hostetler"],
      licenses: ["Apache-2.0"],
      links: %{
        "Changelog" => "https://hexdocs.pm/jidoka/changelog.html",
        "Discord" => "https://jido.run/discord",
        "Documentation" => "https://hexdocs.pm/jidoka",
        "GitHub" => @source_url,
        "Website" => "https://jido.run"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras:
        [
          "README.md",
          "CHANGELOG.md",
          "CONTRIBUTING.md",
          "usage-rules.md",
          "LICENSE"
        ] ++ Path.wildcard("guides/*.{md,livemd}") ++ Path.wildcard("livebook/*.livemd")
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      install_hooks: ["git_hooks.install"],
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo",
        "dialyzer",
        "doctor --raise"
      ]
    ]
  end
end
