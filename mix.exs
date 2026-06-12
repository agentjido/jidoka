defmodule Jidoka.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/mikehostetler/jidoka"

  def project do
    [
      app: :jidoka,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      dialyzer: [plt_add_apps: [:mix], ignore_warnings: ".dialyzer_ignore.exs"],
      escript: escript(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      name: "Jidoka",
      description: description(),
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def cli do
    [preferred_envs: [dialyzer: :dev]]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Jidoka.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jido, "~> 2.3"},
      {:jido_ai, "~> 2.2"},
      {:jido_signal, "~> 2.2"},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.40", only: [:dev], runtime: false}
    ]
  end

  defp escript do
    [main_module: Jidoka.CLI, name: "jidoka", app: nil]
  end

  defp aliases do
    [precommit: ["format --check-formatted"]]
  end

  defp description do
    "A local-first, OTP-native runtime for durable coding sessions on top of Jido."
  end

  defp docs do
    [
      main: "readme",
      extras: [
        {"README.md", title: "Overview"},
        {"guides/concepts.md", title: "Concepts"},
        {"CHANGELOG.md", title: "Changelog"}
      ],
      groups_for_extras: [
        Guides: ["guides/concepts.md"]
      ],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp package do
    [
      files: ~w(lib priv guides mix.exs README.md LICENSE CHANGELOG.md),
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end
end
