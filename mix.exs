defmodule Jidoka.MixProject do
  use Mix.Project

  @version "0.8.0-beta.1"
  @source_url "https://github.com/agentjido/jidoka"
  @description "A data-driven agent framework for the Jido ecosystem with a Spark DSL and durable turn runtime."

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
        export: "cov",
        ignore_modules: [
          ~r/^Jidoka\.Agent\.Dsl(\.|$)/,
          ~r/^Jidoka\.Agent\.Verifiers\./,
          ~r/^Jidoka\.Kino(\.|$)/,
          ~r/^Jidoka\.Workflow\.Dsl(\.|$)/,
          ~r/^Jidoka\.IntegrationSupport\./,
          ~r/^Jidoka\.TestSupport(\.|$)/
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
      # Jido ecosystem
      {:ash_jido, "~> 1.0"},
      {:jido, "~> 2.3"},
      {:jido_action, "~> 2.3"},
      {:jido_ai, "~> 2.2"},
      {:jido_browser, "~> 2.1"},
      {:jido_memory, "~> 1.0"},
      {:jido_mcp, "~> 1.0"},

      # Runtime support
      {:jason, "~> 1.4"},
      {:lua, "~> 1.0.0-rc.0"},
      {:req_llm, "~> 1.12"},
      {:runic, "~> 0.1.0-alpha.7"},
      {:splode, "~> 0.3.0"},
      {:spark, "~> 2.6"},
      {:yaml_elixir, "~> 2.12"},
      {:ymlr, "~> 5.0"},
      {:zoi, "~> 0.18"},

      # Development, test, and release tooling
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false},
      {:sourceror, "~> 1.7", only: [:dev, :test], runtime: false}
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
      main: "getting-started",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras:
        [
          "README.md",
          "CHANGELOG.md",
          "CONTRIBUTING.md",
          "usage-rules.md",
          "LICENSE"
        ] ++ guide_extras() ++ Path.wildcard("livebook/*.livemd"),
      groups_for_extras: groups_for_extras(),
      groups_for_modules: groups_for_modules(),
      nest_modules_by_prefix: nested_module_prefixes()
    ]
  end

  # Explicit guide list.
  defp guide_extras do
    [
      # ── Introduction ─────────────────────────────────────────────────────
      "guides/getting-started.md",
      "guides/core-concepts.md",
      "guides/public-facade.md",
      "guides/configuration.md",

      # ── Building Agents ──────────────────────────────────────────────────
      "guides/agent-dsl.md",
      "guides/tools-and-operations.md",
      "guides/agent-orchestration.md",
      "guides/workflows.md",
      "guides/structured-results.md",
      "guides/controls.md",
      "guides/memory.md",
      "guides/handoffs.md",
      "guides/import-json-yaml.md",
      "guides/inspection-and-preflight.md",
      "guides/testing-and-evals.md",

      # ── Operating Agents ─────────────────────────────────────────────────
      "guides/runtime-and-harness.md",
      "guides/sessions-and-stores.md",
      "guides/snapshots-and-resume.md",
      "guides/human-in-the-loop.md",
      "guides/tracing-and-events.md",
      "guides/streaming.md",
      "guides/agent-view.md",
      "guides/idempotency-and-safety.md",

      # ── Integrations ─────────────────────────────────────────────────────
      "guides/live-llm-tool-loop.md",
      "guides/jido-process-integration.md",
      "guides/ash-jido.md",
      "guides/browser-tools.md",
      "guides/mcp-tools.md",
      "guides/skill-workflow-subagent-tools.md",
      "guides/kino-notebooks.md",

      # ── Reference / Data Contracts ───────────────────────────────────────
      "guides/agent-spec-contract.md",
      "guides/turn-and-effect-contracts.md",
      "guides/operation-source-contracts.md",
      "guides/memory-contracts.md",
      "guides/import-and-snapshot-contracts.md",
      "guides/errors-and-config-reference.md",

      # ── Developer / Internals ────────────────────────────────────────────
      "guides/runic-spine-internals.md",
      "guides/turn-runner-and-effect-interpreter.md",
      "guides/runtime-capabilities-internals.md",
      "guides/projection-internals.md",
      "guides/contributor-testing.md",

      # ── Appendix ─────────────────────────────────────────────────────────
      "guides/glossary.md",
      "guides/troubleshooting.md"
    ]
  end

  defp groups_for_extras do
    [
      Introduction: ~r{guides/(getting-started|core-concepts|public-facade|configuration)\.md},
      "Building Agents":
        ~r{guides/(agent-dsl|tools-and-operations|agent-orchestration|workflows|structured-results|controls|memory|handoffs|import-json-yaml|inspection-and-preflight|testing-and-evals)\.md},
      "Operating Agents":
        ~r{guides/(runtime-and-harness|sessions-and-stores|snapshots-and-resume|human-in-the-loop|tracing-and-events|streaming|agent-view|idempotency-and-safety)\.md},
      Integrations:
        ~r{guides/(live-llm-tool-loop|jido-process-integration|ash-jido|browser-tools|mcp-tools|skill-workflow-subagent-tools|kino-notebooks)\.md},
      Reference:
        ~r{guides/(agent-spec-contract|turn-and-effect-contracts|operation-source-contracts|memory-contracts|import-and-snapshot-contracts|errors-and-config-reference)\.md},
      Internals:
        ~r{guides/(runic-spine-internals|turn-runner-and-effect-interpreter|runtime-capabilities-internals|projection-internals|contributor-testing)\.md},
      Appendix: ~r{guides/(glossary|troubleshooting)\.md},
      Livebooks: ~r{livebook/.*\.livemd}
    ]
  end

  defp groups_for_modules do
    [
      "Main API": [
        Jidoka,
        Jidoka.Agent,
        Jidoka.Action,
        Jidoka.Control,
        Jidoka.ApprovalPredicate,
        Jidoka.Context,
        Jidoka.Session,
        Jidoka.Stream,
        Jidoka.AgentView
      ],
      "Agent Data": [
        Jidoka.Agent.Message,
        Jidoka.Agent.State,
        ~r/^Jidoka\.Agent\.Spec(\.|$)/
      ],
      Controls: [
        ~r/^Jidoka\.Controls\./
      ],
      "Turns And Effects": [
        ~r/^Jidoka\.Chat\./,
        ~r/^Jidoka\.Turn\./,
        ~r/^Jidoka\.Effect\./,
        Jidoka.Event,
        Jidoka.Usage
      ],
      "Sessions, Reviews, And Handoffs": [
        Jidoka.Runtime.AgentSnapshot,
        ~r/^Jidoka\.Harness\.(Session|Store)(\.|$)/,
        ~r/^Jidoka\.Review(\.|$)/,
        ~r/^Jidoka\.Handoff(\.|$)/
      ],
      "Tools And Operation Sources": [
        Jidoka.Browser,
        ~r/^Jidoka\.Browser\.Tools\./,
        ~r/^Jidoka\.Operation\.Source(\.|$)/,
        Jidoka.Skill,
        ~r/^Jidoka\.Workflow(\.|$)/
      ],
      "Import, Export, And Inspection": [
        Jidoka.Import,
        Jidoka.Import.AgentDocument,
        Jidoka.Export,
        Jidoka.Debug,
        ~r/^Jidoka\.Debug\./,
        Jidoka.Inspection,
        Jidoka.Inspection.Preflight,
        Jidoka.Projection
      ],
      "Memory, Trace, And Eval": [
        ~r/^Jidoka\.Memory(\.|$)/,
        ~r/^Jidoka\.Trace(\.|$)/,
        ~r/^Jidoka\.Eval(\.|$)/
      ],
      "Jido Integration": [
        Jidoka.Jido,
        ~r/^Jidoka\.Runtime\.Actions\./,
        Jidoka.Runtime.AgentServerState,
        Jidoka.Runtime.Signals
      ],
      Livebook: [
        Jidoka.Kino
      ],
      "Runtime Internals": [
        Jidoka.Harness,
        Jidoka.Harness.Replay,
        ~r/^Jidoka\.Runtime\./
      ],
      "Configuration And Errors": [
        Jidoka.Config,
        Jidoka.Error,
        Jidoka.Id,
        Jidoka.Schema
      ]
    ]
  end

  defp nested_module_prefixes do
    [
      Jidoka.Agent.Spec,
      Jidoka.Browser.Tools,
      Jidoka.Chat,
      Jidoka.Controls,
      Jidoka.Effect,
      Jidoka.Eval,
      Jidoka.Handoff,
      Jidoka.Harness,
      Jidoka.Import,
      Jidoka.Debug,
      Jidoka.Inspection,
      Jidoka.Kino,
      Jidoka.Memory,
      Jidoka.Operation.Source,
      Jidoka.Review,
      Jidoka.Runtime,
      Jidoka.Trace,
      Jidoka.Turn,
      Jidoka.Workflow
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
