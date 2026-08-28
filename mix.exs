defmodule Jidoka.MixProject do
  use Mix.Project

  @version "0.9.1"
  @source_url "https://github.com/agentjido/jidoka"
  @description "A data-driven agent framework for the Jido ecosystem with a Spark DSL and durable turn runtime."

  def project do
    [
      app: :jidoka,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_pattern: "*_test.exs",
      test_paths: test_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
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
          # The notebook layer is not compiled in production.
          ~r/^Jidoka\.Kino(?:\.|$)/,
          # Modules compiled only to support repository tests.
          ~r/^Jidoka\.(?:IntegrationSupport|TestSupport|ParityCase)(?:\.|$)/,
          # Complete reference applications are not part of library coverage.
          ~r/^JidokaExamples(\.|$)/,
          # Spark emits macro helper modules from dependency source. The typed
          # DSL entities remain covered through their package-owned modules.
          ~r/^Jidoka\.Agent\.Dsl\.(?:Jidoka\.Agent|Tools\.|Controls\.)/,
          ~r/^Jidoka\.Workflow\.Dsl\.Steps\./
        ],
        summary: [threshold: 90]
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
      {:ash_jido, "~> 1.0 and >= 1.0.1"},
      {:jido, "~> 2.3"},
      {:jido_action, "~> 2.3"},
      {:jido_ai, "~> 2.2"},
      {:jido_browser, "~> 2.1"},
      {:jido_mcp, "~> 1.0"},

      # Runtime support
      {:crontab, "~> 1.2"},
      {:jason, "~> 1.4"},
      {:jsv, "~> 0.22"},
      {:llm_db, "~> 2026.8.4"},
      {:lua, "~> 1.0.0-rc.0"},
      {:req_llm, "~> 1.21.0"},
      {:runic, "~> 0.1.0-alpha.7"},
      {:splode, "~> 0.3.0"},
      {:spark, "~> 2.6"},
      {:time_zone_info, "~> 0.7"},
      {:yaml_elixir, "~> 2.12"},
      {:ymlr, "~> 5.1.6"},
      {:zoi, "~> 0.18"},

      # Development, test, and release tooling
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false},
      {:sourceror, "~> 1.7", only: [:dev, :test]}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"] ++ example_paths()
  defp elixirc_paths(_env), do: ["lib"]

  defp example_paths do
    "examples/*/lib"
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort()
  end

  defp package do
    [
      files: [
        "lib",
        "guides",
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
        ] ++ guide_extras() ++ example_extras(),
      groups_for_extras: groups_for_extras(),
      groups_for_modules: groups_for_modules(),
      groups_for_docs: groups_for_docs(),
      filter_modules: fn module, _metadata -> include_module_in_docs?(module) end,
      skip_code_autolink_to: &internal_documentation_reference?/1,
      skip_undefined_reference_warnings_on: &internal_documentation_reference?/1,
      nest_modules_by_prefix: nested_module_prefixes()
    ]
  end

  # Explicit guide list.
  defp guide_extras do
    [
      # ── Start Here ───────────────────────────────────────────────────────
      "guides/getting-started.md",
      "guides/documentation-overview.md",
      "guides/core-concepts.md",

      # ── Build Agents ─────────────────────────────────────────────────────
      "guides/agent-dsl.md",
      "guides/tools-and-operations.md",
      "guides/structured-results.md",
      "guides/controls.md",
      "guides/memory.md",
      "guides/import-json-yaml.md",
      "guides/inspection-and-preflight.md",
      "guides/testing-and-evals.md",

      # ── Compose Work ─────────────────────────────────────────────────────
      "guides/workflows.md",
      "guides/agent-orchestration.md",
      "guides/handoffs.md",

      # ── Operate Agents ───────────────────────────────────────────────────
      "guides/configuration.md",
      "guides/sessions-and-stores.md",
      "guides/snapshots-and-resume.md",
      "guides/human-in-the-loop.md",
      "guides/tracing-and-events.md",
      "guides/streaming.md",
      "guides/agent-view.md",
      "guides/idempotency-and-safety.md",
      "guides/runtime-limits.md",
      "guides/capability-replay.md",
      "guides/policy-gate.md",
      "guides/constrained-execution-contracts.md",
      "guides/extension-architecture.md",
      "guides/process-extensions.md",
      "guides/coding-pack.md",
      "guides/decisions/litterbox-adapter.md",

      # ── Integrations ─────────────────────────────────────────────────────
      "guides/live-llm-tool-loop.md",
      "guides/jido-process-integration.md",
      "guides/ash-jido.md",
      "guides/browser-tools.md",
      "guides/mcp-tools.md",
      "guides/skill-workflow-subagent-tools.md",
      "guides/kino-notebooks.md",

      # ── Public Contract Reference ────────────────────────────────────────
      "guides/public-facade.md",
      "guides/agent-spec-contract.md",
      "guides/turn-and-effect-contracts.md",
      "guides/operation-source-contracts.md",
      "guides/memory-contracts.md",
      "guides/import-and-snapshot-contracts.md",
      "guides/errors-and-config-reference.md",

      # ── Architecture / Internals ─────────────────────────────────────────
      "guides/architecture-boundaries.md",
      "guides/runtime-and-harness.md",
      "guides/runic-spine-internals.md",
      "guides/turn-runner-and-effect-interpreter.md",
      "guides/runtime-capabilities-internals.md",
      "guides/projection-internals.md",
      "guides/contributor-testing.md",

      # ── Help ─────────────────────────────────────────────────────────────
      "guides/glossary.md",
      "guides/troubleshooting.md"
    ]
  end

  defp groups_for_extras do
    [
      "Start Here": ~r{guides/(getting-started|documentation-overview|core-concepts)\.md},
      "Build Agents":
        ~r{guides/(agent-dsl|tools-and-operations|structured-results|controls|memory|import-json-yaml|inspection-and-preflight|testing-and-evals)\.md},
      "Compose Work": ~r{guides/(workflows|agent-orchestration|handoffs)\.md},
      "Operate Agents":
        ~r{guides/(configuration|sessions-and-stores|snapshots-and-resume|human-in-the-loop|tracing-and-events|streaming|agent-view|idempotency-and-safety|runtime-limits|capability-replay|policy-gate|constrained-execution-contracts|extension-architecture|process-extensions)\.md},
      Decisions: ~r{guides/decisions/.+\.md},
      Integrations:
        ~r{guides/(live-llm-tool-loop|jido-process-integration|ash-jido|browser-tools|mcp-tools|skill-workflow-subagent-tools|kino-notebooks)\.md},
      "Public Contract Reference":
        ~r{guides/(public-facade|agent-spec-contract|turn-and-effect-contracts|operation-source-contracts|memory-contracts|import-and-snapshot-contracts|errors-and-config-reference)\.md},
      "Architecture And Internals":
        ~r{guides/(architecture-boundaries|runtime-and-harness|runic-spine-internals|turn-runner-and-effect-interpreter|runtime-capabilities-internals|projection-internals|contributor-testing)\.md},
      Help: ~r{guides/(glossary|troubleshooting)\.md},
      Examples: ~r{examples/(?:README|[^/]+/README)\.md},
      Livebooks: ~r{(?:examples/.+|guides/livebooks)/.*\.livemd},
      Project: ~r{^(?:README|CHANGELOG|CONTRIBUTING|usage-rules)\.md$|^LICENSE$}
    ]
  end

  defp groups_for_modules do
    [
      "Primary Application API": [
        Jidoka,
        Jidoka.Agent,
        Jidoka.Action,
        Jidoka.Context,
        Jidoka.Control,
        Jidoka.Session,
        Jidoka.Stream,
        Jidoka.Workflow,
        Jidoka.Config
      ],
      "Optional Feature APIs": [
        Jidoka.AgentView,
        Jidoka.ApprovalPredicate,
        Jidoka.Browser,
        Jidoka.Debug,
        Jidoka.Eval,
        Jidoka.Export,
        Jidoka.Import,
        Jidoka.Inspection,
        Jidoka.Instructions,
        Jidoka.Jido,
        Jidoka.Memory,
        Jidoka.ModelPolicy,
        ~r/^Jidoka\.Replay(\.|$)/,
        Jidoka.Skill,
        Jidoka.Trace
      ],
      "Agent And Turn Contracts": [
        Jidoka.Cancellation,
        Jidoka.ContentPart,
        Jidoka.Chat.Request,
        Jidoka.Agent.Message,
        Jidoka.Agent.State,
        ~r/^Jidoka\.Agent\.Spec(\.|$)/,
        ~r/^Jidoka\.Turn\./,
        ~r/^Jidoka\.Effect\./,
        Jidoka.Event,
        Jidoka.Usage
      ],
      "State And Policy Contracts": [
        Jidoka.Snapshot,
        ~r/^Jidoka\.Controls\./,
        ~r/^Jidoka\.Session\.(Data|Store|Lease|Lineage|Replay|Sequence|Transitions)(\.|$)/,
        ~r/^Jidoka\.Review(\.|$)/,
        ~r/^Jidoka\.Handoff(\.|$)/,
        ~r/^Jidoka\.Memory\./,
        ~r/^Jidoka\.Trace\./,
        ~r/^Jidoka\.Error(\.|$)/,
        Jidoka.Id
      ],
      "Tool And Workflow Contracts": [
        Jidoka.Operation.Capability,
        ~r/^Jidoka\.Operation\.Source(\.|$)/,
        ~r/^Jidoka\.Workflow(\.|$)/
      ],
      "Feature Data Contracts": [
        Jidoka.Import.AgentDocument,
        ~r/^Jidoka\.Debug\./,
        Jidoka.Inspection.Preflight,
        ~r/^Jidoka\.Eval\./
      ],
      "Advanced Extension Support": [
        Jidoka.Adapter.Jido.Actions,
        Jidoka.Adapter.Jido.AgentServerState,
        Jidoka.Adapter.ReqLLM,
        ~r/^Jidoka\.Runtime\.(Capabilities|Limits)(\.|$)/,
        Jidoka.Runtime.Controls.OperationContext,
        Jidoka.Runtime.LocalOperations
      ],
      "Development And Test": [
        Jidoka.Kino
      ]
    ]
  end

  defp groups_for_docs do
    [
      Build: root_docs([:agent, :agent!, :plan, :plan!, :import, :export]),
      Run: root_docs([:chat, :turn, :resume]),
      Async: root_docs([:chat_async, :stream, :await, :cancel]),
      Sessions: root_docs([:session, :fork_session, :recover_session]),
      Review: root_docs([:pending_reviews, :approve, :deny]),
      "Process Host": root_docs([:start_agent, :whereis, :await_agent, :stop_agent]),
      Inspect: root_docs([:preflight, :inspect, :project]),
      Handoff: root_docs([:handoff, :reset_handoff]),
      Errors: root_docs([:normalize_error, :format_error, :error_to_map])
    ]
  end

  defp root_docs(names) do
    fn metadata -> metadata[:module] == Jidoka and metadata[:name] in names end
  end

  defp include_module_in_docs?(module), do: module not in internal_documentation_modules()

  defp internal_documentation_reference?(reference) when is_binary(reference) do
    reference = String.trim_leading(reference, "t:")

    Enum.any?(internal_documentation_modules(), fn module ->
      module_name = inspect(module)

      case String.split_at(reference, String.length(module_name)) do
        {^module_name, ""} ->
          true

        {^module_name, "." <> suffix} ->
          suffix != "" and String.first(suffix) == String.downcase(String.first(suffix))

        _other ->
          false
      end
    end)
  end

  defp internal_documentation_reference?(_reference), do: false

  defp internal_documentation_modules do
    [
      Jidoka.Adapter.Jido.Browser.Tools.ReadPage,
      Jidoka.Adapter.Jido.Browser.Tools.SearchWeb,
      Jidoka.Adapter.Jido.Browser.Tools.SnapshotUrl,
      Jidoka.Adapter.Jido.RunTurn,
      Jidoka.Adapter.Jido.Signals,
      Jidoka.Adapter.Jido.Skill,
      Jidoka.Adapter.ReqLLM.Decision,
      Jidoka.Adapter.Runic.Background,
      Jidoka.Adapter.Runic.TurnCompiler,
      Jidoka.Harness,
      Jidoka.Projection,
      Jidoka.Review.Execution,
      Jidoka.Runtime.Controls,
      Jidoka.Runtime.Controls.Operation,
      Jidoka.Runtime.EffectInterpreter,
      Jidoka.Runtime.Review,
      Jidoka.Runtime.Spine.Steps,
      Jidoka.Runtime.TurnRunner,
      Jidoka.Schema,
      Jidoka.Session.Execution,
      Jidoka.Turn.Execution
    ]
  end

  defp nested_module_prefixes do
    [
      Jidoka.Agent.Spec,
      Jidoka.Adapter,
      Jidoka.Adapter.Jido,
      Jidoka.Adapter.ReqLLM,
      Jidoka.Adapter.Runic,
      Jidoka.Adapter.Jido.Browser.Tools,
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
      Jidoka.Replay,
      Jidoka.Runtime,
      Jidoka.Session,
      Jidoka.Trace,
      Jidoka.Turn,
      Jidoka.Workflow
    ]
  end

  defp aliases do
    [
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "xref graph --format cycles --fail-above 0",
        "cmd env MIX_ENV=test mix test test/architecture/boundaries_test.exs",
        "credo",
        "dialyzer",
        "doctor --raise"
      ]
    ]
  end

  defp example_extras do
    (["examples/README.md"] ++
       Path.wildcard("examples/*/README.md") ++
       Path.wildcard("examples/*/*.livemd") ++
       Path.wildcard("guides/livebooks/*.livemd"))
    |> Enum.filter(&File.regular?/1)
  end

  defp test_paths(:test), do: ["test", "examples"]
  defp test_paths(_env), do: []
end
