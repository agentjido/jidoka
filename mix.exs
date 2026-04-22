defmodule Jidoka.MixProject do
  use Mix.Project

  def project do
    [
      app: :jidoka,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      dialyzer: [plt_add_apps: [:mix], ignore_warnings: ".dialyzer_ignore.exs"],
      escript: escript(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps()
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
      {:jido, "~> 2.2"},
      {:jido_ai, "~> 2.1"},
      {:jido_signal, "~> 2.1.0"},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp escript do
    [main_module: Jidoka.CLI, name: "jidoka", app: nil]
  end

  defp aliases do
    [precommit: ["format --check-formatted"]]
  end
end
