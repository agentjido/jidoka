defmodule Jidoka.MixProject do
  use Mix.Project

  @version "1.0.0-beta.1"
  @source_url "https://github.com/agentjido/jidoka"
  @description "Developer-friendly LLM agent harness built on Jido and Jido.AI."
  @coverage_threshold 75

  def project do
    [
      app: :jidoka,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "Jidoka",
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),
      test_coverage: [
        tool: ExCoveralls,
        summary: [threshold: @coverage_threshold],
        export: "cov",
        ignore_modules: [
          ~r/^JidokaTest\./,
          ~r/^Jidoka\.Agent\.Dsl(\.|$)/,
          ~r/^Jidoka\.Workflow\.Dsl(\.|$)/,
          Jidoka.AgentView.Run,
          Jidoka.Guardrails.Input,
          Jidoka.Guardrails.Output,
          Jidoka.Guardrails.Tool,
          Jidoka.Hooks.Input,
          Jidoka.Trace.Event,
          Jidoka.Workflow.Runtime.Keys
        ]
      ],
      dialyzer: [
        plt_add_apps: [:mix, :llm_db],
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt"
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.github": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Jidoka.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash_jido, "~> 1.0"},
      {:dotenvy, "~> 1.1"},
      {:jason, "~> 1.4"},
      {:jido, "~> 2.3"},
      {:jido_ai, "~> 2.2"},
      {:jido_character, "~> 1.0"},
      {:jido_browser, "~> 2.1"},
      {:jido_mcp, "~> 1.0"},
      {:jido_memory, "~> 1.0"},
      {:jido_runic, "~> 1.0"},
      {:mdex, "~> 0.12.1"},
      {:plug, "~> 1.18"},
      {:spark, "~> 2.6"},
      {:yaml_elixir, "~> 2.12"},
      {:zoi, "~> 0.18"},
      {:splode, "~> 0.3.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.21", only: :dev, runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false}
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
        "credo --min-priority higher",
        "dialyzer",
        "doctor --raise"
      ]
    ]
  end

  defp package do
    [
      name: "jidoka",
      files: [
        "lib",
        "examples",
        "guides",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "LICENSE",
        "usage-rules.md"
      ],
      build_tools: ["mix"],
      maintainers: ["Mike Hostetler"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Documentation" => "https://hexdocs.pm/jidoka",
        "Changelog" => "https://hexdocs.pm/jidoka/changelog.html",
        "Website" => "https://jido.run"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras:
        [
          "README.md"
        ] ++
          guide_extras() ++
          [
            "CHANGELOG.md",
            "CONTRIBUTING.md",
            "LICENSE",
            "usage-rules.md"
          ],
      groups_for_extras: [
        Orientation: [
          "guides/overview.md",
          "guides/getting-started.md"
        ],
        "Agent Fundamentals": [
          "guides/agents.md",
          "guides/models.md",
          "guides/instructions.md",
          "guides/context.md",
          "guides/structured-output.md",
          "guides/chat-turn.md"
        ],
        "Runtime Integration": [
          "guides/running-agents.md",
          "guides/sessions.md",
          "guides/schedules.md",
          "guides/agent-view.md",
          "guides/phoenix-liveview.md",
          "guides/graduating-to-jido.md"
        ],
        Capabilities: [
          "guides/tools.md",
          "guides/ash-resources.md",
          "guides/mcp-tools.md",
          "guides/web-access.md",
          "guides/skills.md",
          "guides/plugins.md"
        ],
        Orchestration: [
          "guides/subagents.md",
          "guides/workflows.md",
          "guides/handoffs.md"
        ],
        Lifecycle: [
          "guides/memory.md",
          "guides/compaction.md",
          "guides/characters.md",
          "guides/hooks.md",
          "guides/guardrails.md"
        ],
        Imports: [
          "guides/imported-agents.md"
        ],
        Operations: [
          "guides/errors.md",
          "guides/inspection.md",
          "guides/tracing.md",
          "guides/testing-agents.md",
          "guides/evals.md",
          "guides/mix-tasks.md",
          "guides/livebooks.md",
          "guides/examples.md",
          "guides/production.md"
        ],
        Reference: [
          "usage-rules.md",
          "CHANGELOG.md",
          "CONTRIBUTING.md",
          "LICENSE"
        ]
      ],
      groups_for_modules: [
        Agents: [
          Jidoka.Agent,
          Jidoka.Agent.SystemPrompt,
          Jidoka.AgentView,
          Jidoka.Agent.View,
          Jidoka.ImportedAgent,
          Jidoka.ImportedAgent.Subagent
        ],
        Workflows: [
          Jidoka.Workflow
        ],
        Runtime: [
          Jidoka,
          Jidoka.Session,
          Jidoka.Kino,
          Jidoka.Runtime,
          Jidoka.Schedule,
          Jidoka.Schedule.Manager,
          Jidoka.Compaction,
          Jidoka.Compaction.Prompt,
          Jidoka.Trace,
          Jidoka.Trace.Event,
          Jidoka.Interrupt,
          Jidoka.Handoff
        ],
        Extensions: [
          Jidoka.Character,
          Jidoka.Tool,
          Jidoka.Plugin,
          Jidoka.Hook,
          Jidoka.Guardrail,
          Jidoka.Web,
          Jidoka.Subagent,
          Jidoka.Handoff.Capability,
          Jidoka.MCP
        ],
        Errors: [
          Jidoka.Error
        ]
      ]
    ]
  end

  defp guide_extras do
    [
      # Orientation
      "guides/overview.md",
      "guides/getting-started.md",
      # Agent fundamentals
      "guides/agents.md",
      "guides/models.md",
      "guides/instructions.md",
      "guides/context.md",
      "guides/structured-output.md",
      "guides/chat-turn.md",
      # Runtime integration
      "guides/running-agents.md",
      "guides/sessions.md",
      "guides/schedules.md",
      "guides/agent-view.md",
      "guides/phoenix-liveview.md",
      "guides/graduating-to-jido.md",
      # Capabilities
      "guides/tools.md",
      "guides/ash-resources.md",
      "guides/mcp-tools.md",
      "guides/web-access.md",
      "guides/skills.md",
      "guides/plugins.md",
      # Orchestration
      "guides/subagents.md",
      "guides/workflows.md",
      "guides/handoffs.md",
      # Lifecycle
      "guides/memory.md",
      "guides/compaction.md",
      "guides/characters.md",
      "guides/hooks.md",
      "guides/guardrails.md",
      # Imports
      "guides/imported-agents.md",
      # Operations
      "guides/errors.md",
      "guides/inspection.md",
      "guides/tracing.md",
      "guides/testing-agents.md",
      "guides/evals.md",
      "guides/mix-tasks.md",
      "guides/livebooks.md",
      "guides/examples.md",
      "guides/production.md"
    ]
  end
end
