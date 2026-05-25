defmodule JidokaTest.ImportedAgentTest do
  use JidokaTest.Support.Case, async: false

  alias JidokaTest.{
    AddNumbers,
    ApproveLargeMathToolGuardrail,
    BillingHandoffSpecialist,
    InjectTenantHook,
    InterruptBeforeHook,
    MathPlugin,
    ModuleMathSkill,
    NormalizeReplyHook,
    NotifyOpsHook,
    ResearchSpecialist,
    RestrictRefundsHook,
    ReviewSpecialist,
    SafePromptGuardrail,
    SafeReplyGuardrail,
    SupportCharacter,
    WorkflowCapability
  }

  defmodule ImportedCollisionA do
    use Jidoka.Agent

    agent :collision_child do
      instructions "First imported collision child."
    end
  end

  defmodule ImportedCollisionB do
    use Jidoka.Agent

    agent :collision_child do
      instructions "Second imported collision child."
    end
  end

  defmodule MetadataOnlyPlugin do
    use Jidoka.Plugin, name: "metadata_plugin", tools: []
  end

  test "imports a constrained imported agent from JSON" do
    json =
      imported_spec("json_agent",
        instructions: "You are a concise assistant.",
        context: %{"tenant" => "json", "channel" => "imported"},
        capabilities: %{
          "tools" => ["add_numbers"],
          "plugins" => ["math_plugin"]
        },
        lifecycle: %{
          "hooks" => %{
            "before_turn" => ["inject_tenant", "restrict_refunds"],
            "after_turn" => ["normalize_reply"],
            "on_interrupt" => ["notify_ops"]
          },
          "guardrails" => %{
            "input" => ["safe_prompt"],
            "output" => ["safe_reply"],
            "tool" => ["approve_large_math_tool"]
          }
        }
      )
      |> Jason.encode!(pretty: true)

    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent(
               json,
               available_tools: [AddNumbers],
               available_plugins: [MathPlugin],
               available_hooks: [
                 InjectTenantHook,
                 RestrictRefundsHook,
                 NormalizeReplyHook,
                 NotifyOpsHook
               ],
               available_guardrails: [
                 SafePromptGuardrail,
                 SafeReplyGuardrail,
                 ApproveLargeMathToolGuardrail
               ]
             )

    assert {:ok, encoded} = Jidoka.encode_agent(agent, format: :json)
    assert encoded =~ "\"id\": \"json_agent\""
    assert encoded =~ "\"model\": \"fast\""
    assert encoded =~ "\"context\": {"
    assert encoded =~ "\"tools\": ["
    assert encoded =~ "\"plugins\": ["
    assert encoded =~ "\"hooks\""
    assert encoded =~ "\"guardrails\""
    assert agent.spec.context == %{"tenant" => "json", "channel" => "imported"}
    assert agent.tool_modules == [AddNumbers, JidokaTest.MultiplyNumbers]
    assert agent.plugin_modules == [MathPlugin]
    assert agent.hook_modules.before_turn == [InjectTenantHook, RestrictRefundsHook]
    assert agent.hook_modules.after_turn == [NormalizeReplyHook]
    assert agent.hook_modules.on_interrupt == [NotifyOpsHook]
    assert agent.guardrail_modules.input == [SafePromptGuardrail]
    assert agent.guardrail_modules.output == [SafeReplyGuardrail]
    assert agent.guardrail_modules.tool == [ApproveLargeMathToolGuardrail]
  end

  test "JSON and YAML round-trip the full supported imported spec contract" do
    output = %{
      "schema" => %{
        "type" => "object",
        "required" => ["summary"],
        "properties" => %{"summary" => %{"type" => "string"}}
      },
      "retries" => 1,
      "on_validation_error" => "repair"
    }

    source = %{
      "agent" => %{
        "id" => "full_round_trip_agent",
        "description" => "Portable imported agent.",
        "context" => %{"tenant" => "acme", "channel" => "support"}
      },
      "defaults" => %{
        "model" => %{"provider" => "openai", "id" => "gpt-4.1", "base_url" => "http://localhost:4000/v1"},
        "instructions" => "Line one.\nLine two.",
        "character" => %{"name" => "Imported Specialist", "identity" => %{"role" => "Support"}}
      },
      "capabilities" => %{
        "tools" => ["add_numbers"],
        "skills" => ["module-math-skill"],
        "skill_paths" => ["test/fixtures/skills"],
        "mcp_tools" => [%{"endpoint" => "github", "prefix" => "github_"}],
        "subagents" => [
          %{
            "agent" => "research_agent",
            "as" => "research_delegate",
            "description" => "Ask research to handle one bounded task.",
            "target" => "peer",
            "peer_id" => "research-peer",
            "timeout_ms" => 12_345,
            "forward_context" => %{"mode" => "only", "keys" => ["tenant"]},
            "result" => "structured"
          }
        ],
        "workflows" => [
          %{
            "workflow" => "workflow_capability_math",
            "as" => "run_math",
            "description" => "Run deterministic math.",
            "timeout" => 23_456,
            "forward_context" => "none",
            "result" => "structured"
          }
        ],
        "handoffs" => [
          %{
            "agent" => "billing_specialist",
            "as" => "billing_owner",
            "description" => "Transfer billing ownership.",
            "target" => "peer",
            "peer_id" => "billing-peer",
            "forward_context" => %{"mode" => "except", "keys" => ["secret"]}
          }
        ],
        "web" => [%{"mode" => "read_only"}],
        "plugins" => ["metadata_plugin"]
      },
      "lifecycle" => %{
        "compaction" => %{
          "mode" => "manual",
          "strategy" => "summary",
          "max_messages" => 40,
          "keep_last" => 8,
          "max_summary_chars" => 2_000,
          "prompt" => "Summarize the useful state."
        },
        "memory" => %{
          "mode" => "conversation",
          "namespace" => "shared",
          "shared_namespace" => "support",
          "capture" => "conversation",
          "retrieve" => %{"limit" => 3},
          "inject" => "instructions"
        },
        "hooks" => %{
          "before_turn" => ["inject_tenant"],
          "after_turn" => ["normalize_reply"],
          "on_interrupt" => ["notify_ops"]
        },
        "guardrails" => %{
          "input" => ["safe_prompt"],
          "output" => ["safe_reply"],
          "tool" => ["approve_large_math_tool"]
        }
      },
      "output" => output
    }

    import_opts = imported_registry_opts()
    assert {:ok, normalized_import_opts} = Jidoka.ImportedAgent.Registries.normalize_opts(import_opts)

    assert {:ok, %ImportedAgent{} = agent} = Jidoka.import_agent(source, import_opts)
    external = Jidoka.ImportedAgent.Spec.to_external_map(agent.spec)

    for format <- [:json, :yaml] do
      assert {:ok, encoded} = Jidoka.encode_agent(agent, format: format)
      assert {:ok, decoded} = Jidoka.ImportedAgent.Codec.decode(encoded, format)
      assert {:ok, round_tripped_spec} = Jidoka.ImportedAgent.Spec.new(decoded, normalized_import_opts)

      assert Jidoka.ImportedAgent.Spec.to_external_map(round_tripped_spec) == external
    end
  end

  test "resolves registry-backed capabilities and output schemas into generated runtime definitions" do
    output = %{
      "schema" => %{
        "type" => "object",
        "required" => ["summary"],
        "properties" => %{"summary" => %{"type" => "string"}}
      },
      "retries" => 1,
      "on_validation_error" => "error"
    }

    spec =
      imported_spec("mapped_registry_agent",
        instructions: "Use mapped registry capabilities.",
        capabilities: %{
          "tools" => ["add_numbers"],
          "subagents" => [%{"agent" => "research_agent", "as" => "research_delegate"}],
          "workflows" => [%{"workflow" => "workflow_capability_math", "as" => "run_math"}],
          "handoffs" => [%{"agent" => "billing_specialist", "as" => "billing_owner"}]
        },
        output: output
      )

    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent(spec,
               available_tools: %{"add_numbers" => AddNumbers},
               available_subagents: %{"research_agent" => ResearchSpecialist},
               available_workflows: %{"workflow_capability_math" => WorkflowCapability.MathWorkflow},
               available_handoffs: %{"billing_specialist" => BillingHandoffSpecialist}
             )

    assert Enum.member?(agent.tool_modules, AddNumbers)
    assert [%Jidoka.Subagent{agent: ResearchSpecialist, name: "research_delegate"}] = agent.subagents

    assert [
             %Jidoka.Workflow.Capability{
               workflow: WorkflowCapability.MathWorkflow,
               name: "run_math"
             }
           ] = agent.workflows

    assert [
             %Jidoka.Handoff.Capability{
               agent: BillingHandoffSpecialist,
               name: "billing_owner"
             }
           ] = agent.handoffs

    assert %Jidoka.Output{schema_kind: :json_schema, retries: 1, on_validation_error: :error} = agent.spec.output

    definition = agent.runtime_module.__jidoka_definition__()

    assert definition.output == agent.spec.output
    assert definition.tool_names == ["add_numbers", "research_delegate", "run_math", "billing_owner"]
  end

  test "imports skills and mcp tool sync settings" do
    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent(
               imported_spec("skills_agent",
                 instructions: "You are skill-aware.",
                 capabilities: %{
                   "skills" => ["module-math-skill"],
                   "mcp_tools" => [%{"endpoint" => "github", "prefix" => "github_"}]
                 }
               ),
               available_skills: [ModuleMathSkill]
             )

    assert agent.skill_refs == [ModuleMathSkill]
    assert agent.mcp_tools == [%{endpoint: "github", prefix: "github_"}]
    assert Enum.member?(agent.tool_modules, JidokaTest.MultiplyNumbers)

    assert {:ok, encoded_json} = Jidoka.encode_agent(agent, format: :json)
    assert encoded_json =~ "\"skills\""
    assert encoded_json =~ "\"mcp_tools\""
  end

  test "imports and runs structured output contracts from JSON Schema specs" do
    output =
      %{
        "schema" => %{
          "type" => "object",
          "required" => ["category", "confidence", "summary"],
          "properties" => %{
            "category" => %{"type" => "string"},
            "confidence" => %{"type" => "number"},
            "summary" => %{"type" => "string"}
          }
        },
        "retries" => 1,
        "on_validation_error" => "repair"
      }

    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent(
               imported_spec("imported_output_agent",
                 instructions: "Classify support tickets.",
                 output: output
               )
             )

    assert %Jidoka.Output{schema_kind: :json_schema, retries: 1, on_validation_error: :repair} = agent.spec.output

    assert {:ok, encoded_json} = Jidoka.encode_agent(agent, format: :json)
    assert encoded_json =~ "\"output\""
    assert encoded_json =~ "\"on_validation_error\": \"repair\""

    assert {:ok, encoded_yaml} = Jidoka.encode_agent(agent, format: :yaml)
    assert encoded_yaml =~ "output:"
    assert encoded_yaml =~ "on_validation_error: repair"

    assert {:ok, %ImportedAgent{} = yaml_agent} = Jidoka.import_agent(encoded_yaml, format: :yaml)
    assert %Jidoka.Output{schema_kind: :json_schema, retries: 1, on_validation_error: :repair} = yaml_agent.spec.output

    runtime = agent.runtime_module
    request_id = "req-imported-output"

    {:ok, runtime_agent, {:ai_react_start, params}} =
      runtime.on_before_cmd(
        new_runtime_agent(runtime),
        {:ai_react_start,
         %{
           query: "Classify this",
           request_id: request_id,
           tool_context: %{}
         }}
      )

    runtime_agent =
      runtime_agent
      |> Jido.AI.Request.start_request(request_id, "Classify this")
      |> Jido.AI.Request.complete_request(
        request_id,
        ~s({"category":"billing","confidence":0.93,"summary":"Invoice question"})
      )

    assert {:ok, runtime_agent, []} = runtime.on_after_cmd(runtime_agent, {:ai_react_start, params}, [])

    assert {:ok, %{"category" => "billing", "confidence" => 0.93, "summary" => "Invoice question"}} =
             Jido.AI.Request.get_result(runtime_agent, request_id)
  end

  test "generated imported capability modules are content addressed by registry identity" do
    spec =
      imported_spec("collision_parent_agent",
        instructions: "Delegate when useful.",
        capabilities: %{"subagents" => [%{"agent" => "collision_child"}]}
      )

    assert {:ok, %ImportedAgent{} = first} =
             Jidoka.import_agent(spec, available_subagents: %{"collision_child" => ImportedCollisionA})

    assert {:ok, %ImportedAgent{} = second} =
             Jidoka.import_agent(spec, available_subagents: %{"collision_child" => ImportedCollisionB})

    assert {:ok, %ImportedAgent{} = first_again} =
             Jidoka.import_agent(spec, available_subagents: %{"collision_child" => ImportedCollisionA})

    assert first.runtime_module != second.runtime_module
    assert first.tool_modules != second.tool_modules
    assert first_again.runtime_module == first.runtime_module
    assert first_again.tool_modules == first.tool_modules
    assert [%Jidoka.Subagent{agent: ImportedCollisionA}] = first.subagents
    assert [%Jidoka.Subagent{agent: ImportedCollisionB}] = second.subagents
    assert Code.ensure_loaded?(first.runtime_module)
    assert Enum.all?(first.tool_modules, &Code.ensure_loaded?/1)
  end

  test "imports inline character maps" do
    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent(
               imported_spec("inline_character_agent",
                 character: %{
                   "name" => "Imported Advisor",
                   "identity" => %{"role" => "Billing support"},
                   "instructions" => ["Use the imported character."]
                 }
               )
             )

    assert agent.spec.character["name"] == "Imported Advisor"
    assert {:character, character} = agent.character_spec
    prompt = Jido.Character.to_system_prompt(character)
    assert prompt =~ "# Character: Imported Advisor"
    assert prompt =~ "- Role: Billing support"

    assert {:ok, encoded_json} = Jidoka.encode_agent(agent, format: :json)
    assert encoded_json =~ "\"character\""

    assert {:ok, encoded_yaml} = Jidoka.encode_agent(agent, format: :yaml)
    assert encoded_yaml =~ "character:"
    assert encoded_yaml =~ "Imported Advisor"
  end

  test "imports character refs through available_characters" do
    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent(
               imported_spec("character_ref_agent", character: "support_advisor"),
               available_characters: %{"support_advisor" => SupportCharacter}
             )

    assert agent.spec.character == "support_advisor"
    assert {:module, SupportCharacter} = agent.character_spec

    request = react_request([%{role: :user, content: "hello"}])
    state = react_state()
    transformer = agent.runtime_module.__jidoka_definition__().request_transformer
    config = react_config(transformer)

    assert {:ok, %{messages: [%{role: :system, content: prompt}, %{role: :user, content: "hello"}]}} =
             transformer.transform_request(
               request,
               state,
               config,
               %{}
             )

    assert prompt =~ "# Character: Support Advisor"
    assert prompt =~ "- Role: Support specialist"
    assert prompt =~ "Use the configured support persona."
    assert prompt =~ "You are concise."
  end

  test "rejects imported character refs without an available registry" do
    assert {:error, reason} =
             Jidoka.import_agent(imported_spec("missing_character_registry_agent", character: "support_advisor"))

    assert reason =~ "available_characters registry"
  end

  test "rejects unknown imported character refs" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("unknown_character_agent", character: "unknown"),
               available_characters: %{"support_advisor" => SupportCharacter}
             )

    assert reason =~ "unknown character"
  end

  test "imports runtime skill paths relative to the spec file" do
    root =
      Path.join(System.tmp_dir!(), "jidoka-imported-skill-#{System.unique_integer([:positive])}")

    skill_dir = Path.join(root, "skills/math-discipline")
    spec_dir = Path.join(root, "agents")
    spec_path = Path.join(spec_dir, "agent.json")

    File.mkdir_p!(skill_dir)
    File.mkdir_p!(spec_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: math-discipline
      description: Runtime skill for imported Jidoka agents.
      allowed-tools: add_numbers
      ---

      # Imported Math Discipline

      Use the add_numbers tool for arithmetic.
      """
    )

    File.write!(
      spec_path,
      Jason.encode!(
        imported_spec("runtime_skill_agent",
          capabilities: %{"skills" => ["math-discipline"], "skill_paths" => ["../skills"]}
        )
      )
    )

    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, %ImportedAgent{} = agent} = Jidoka.import_agent_file(spec_path)
    assert agent.skill_refs == ["math-discipline"]
    assert agent.spec.skill_paths == [Path.expand("../skills", spec_dir)]
  end

  test "imports from a normalized imported-agent spec" do
    assert {:ok, %ImportedAgent{spec: %Jidoka.ImportedAgent.Spec{} = spec}} =
             Jidoka.import_agent(
               imported_spec("spec_agent", capabilities: %{"tools" => ["add_numbers"]}),
               available_tools: [AddNumbers]
             )

    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent(spec, available_tools: [AddNumbers])

    assert {:ok, encoded} = Jidoka.encode_agent(agent, format: :json)
    assert encoded =~ "\"id\": \"spec_agent\""

    assert {:ok, pid} = Jidoka.start_agent(agent, id: "imported-spec-agent")
    assert Jidoka.whereis("imported-spec-agent") == pid
    assert :ok = Jidoka.stop_agent(pid)
  end

  test "imports a constrained imported agent from YAML" do
    yaml = """
    agent:
      id: "yaml_agent"
      context:
        tenant: "yaml"
        channel: "imported"
    defaults:
      model:
        provider: "openai"
        id: "gpt-4.1"
      instructions: |-
        You are a concise assistant.
    capabilities:
      tools:
        - "add_numbers"
      plugins:
        - "math_plugin"
    lifecycle:
      hooks:
        before_turn:
          - "inject_tenant"
          - "restrict_refunds"
        after_turn:
          - "normalize_reply"
        on_interrupt:
          - "notify_ops"
      guardrails:
        input:
          - "safe_prompt"
        output:
          - "safe_reply"
        tool:
          - "approve_large_math_tool"
    """

    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent(
               yaml,
               format: :yaml,
               available_tools: [AddNumbers],
               available_plugins: [MathPlugin],
               available_hooks: [
                 InjectTenantHook,
                 RestrictRefundsHook,
                 NormalizeReplyHook,
                 NotifyOpsHook
               ],
               available_guardrails: [
                 SafePromptGuardrail,
                 SafeReplyGuardrail,
                 ApproveLargeMathToolGuardrail
               ]
             )

    assert {:ok, encoded} = Jidoka.encode_agent(agent, format: :yaml)
    assert encoded =~ "id: \"yaml_agent\""
    assert encoded =~ "provider: \"openai\""
    assert encoded =~ "context:"
    assert encoded =~ "tenant: \"yaml\""
    assert encoded =~ "- \"add_numbers\""
    assert encoded =~ "- \"math_plugin\""
    assert encoded =~ "hooks:"
    assert encoded =~ "- \"notify_ops\""
    assert encoded =~ "guardrails:"
    assert agent.tool_modules == [AddNumbers, JidokaTest.MultiplyNumbers]
    assert agent.spec.context == %{"tenant" => "yaml", "channel" => "imported"}
    assert agent.hook_modules.before_turn == [InjectTenantHook, RestrictRefundsHook]
    assert agent.guardrail_modules.tool == [ApproveLargeMathToolGuardrail]
  end

  test "imports a constrained imported agent from file" do
    path = Path.join(System.tmp_dir!(), "jidoka-imported-agent.json")

    on_exit(fn -> File.rm(path) end)

    File.write!(
      path,
      Jason.encode!(
        imported_spec("file_agent",
          context: %{"tenant" => "file", "channel" => "imported"},
          capabilities: %{"tools" => ["add_numbers"], "plugins" => ["math_plugin"]},
          lifecycle: %{
            "hooks" => %{
              "before_turn" => ["inject_tenant"],
              "after_turn" => ["normalize_reply"],
              "on_interrupt" => ["notify_ops"]
            },
            "guardrails" => %{
              "input" => ["safe_prompt"],
              "output" => ["safe_reply"],
              "tool" => ["approve_large_math_tool"]
            }
          }
        )
      )
    )

    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent_file(
               path,
               available_tools: [AddNumbers],
               available_plugins: [MathPlugin],
               available_hooks: [InjectTenantHook, NormalizeReplyHook, NotifyOpsHook],
               available_guardrails: [
                 SafePromptGuardrail,
                 SafeReplyGuardrail,
                 ApproveLargeMathToolGuardrail
               ]
             )

    assert agent.tool_modules == [AddNumbers, JidokaTest.MultiplyNumbers]
    assert agent.plugin_modules == [MathPlugin]
    assert agent.spec.context == %{"tenant" => "file", "channel" => "imported"}
    assert agent.hook_modules.before_turn == [InjectTenantHook]
    assert agent.guardrail_modules.input == [SafePromptGuardrail]
  end

  test "imports constrained subagents and compiles them into generated tool modules" do
    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent(
               imported_spec("subagent_import_agent",
                 instructions: "You can delegate.",
                 capabilities: %{
                   "subagents" => [
                     %{
                       "agent" => "research_agent",
                       "timeout_ms" => 12_345,
                       "forward_context" => %{"mode" => "only", "keys" => ["tenant"]},
                       "result" => "structured"
                     },
                     %{
                       "agent" => "review_agent",
                       "as" => "review_specialist",
                       "description" => "Ask the review specialist",
                       "target" => "peer",
                       "peer_id_context_key" => "review_peer_id"
                     }
                   ]
                 }
               ),
               available_subagents: [ResearchSpecialist, ReviewSpecialist]
             )

    assert Enum.map(agent.subagents, & &1.name) == ["research_agent", "review_specialist"]

    assert [%{timeout: 12_345, forward_context: {:only, ["tenant"]}, result: :structured}, _] =
             agent.subagents

    assert Enum.sort(Enum.map(agent.tool_modules, & &1.name())) == [
             "research_agent",
             "review_specialist"
           ]

    research_tool =
      Enum.find(agent.tool_modules, fn tool_module -> tool_module.name() == "research_agent" end)

    assert {:ok, %{result: "research:Imported task:tenant=imported:depth=1", subagent: metadata}} =
             research_tool.run(%{task: "Imported task"}, %{tenant: "imported"})

    assert metadata.name == "research_agent"
    assert metadata.context_keys == ["tenant"]

    assert {:ok, encoded_json} = Jidoka.encode_agent(agent, format: :json)
    assert encoded_json =~ "\"subagents\""
    assert encoded_json =~ "\"timeout_ms\": 12345"
    assert encoded_json =~ "\"result\": \"structured\""

    assert {:ok, encoded_yaml} = Jidoka.encode_agent(agent, format: :yaml)
    assert encoded_yaml =~ "subagents:"
    assert encoded_yaml =~ "agent: \"research_agent\""
    assert encoded_yaml =~ "timeout_ms: 12345"
    assert encoded_yaml =~ "result: \"structured\""
  end

  test "imports constrained subagent runtime options from YAML" do
    yaml = """
    agent:
      id: "subagent_yaml_agent"
    defaults:
      model: "fast"
      instructions: "You can delegate."
    capabilities:
      subagents:
        - agent: "research_agent"
          target: "ephemeral"
          timeout_ms: 45000
          forward_context:
            mode: "except"
            keys:
              - "secret"
          result: "structured"
    """

    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent(yaml,
               format: :yaml,
               available_subagents: [ResearchSpecialist]
             )

    assert [%{timeout: 45_000, forward_context: {:except, ["secret"]}, result: :structured}] =
             agent.subagents
  end

  test "imports constrained workflows and compiles them into generated tool modules" do
    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent(
               imported_spec("workflow_import_agent",
                 instructions: "You can run workflows.",
                 capabilities: %{
                   "workflows" => [
                     %{
                       "workflow" => "workflow_capability_math",
                       "as" => "run_math",
                       "description" => "Run the deterministic math workflow",
                       "timeout" => 12_345,
                       "forward_context" => %{"mode" => "none"},
                       "result" => "structured"
                     }
                   ]
                 }
               ),
               available_workflows: [WorkflowCapability.MathWorkflow]
             )

    assert [%{name: "run_math", timeout: 12_345, forward_context: :none, result: :structured}] =
             agent.workflows

    assert Enum.map(agent.tool_modules, & &1.name()) == ["run_math"]

    workflow_tool = hd(agent.tool_modules)

    assert {:ok, %{output: %{value: 12}, workflow: metadata}} =
             workflow_tool.run(%{value: 5}, %{suffix: "ignored"})

    assert metadata.name == "run_math"

    assert {:ok, encoded_json} = Jidoka.encode_agent(agent, format: :json)
    assert encoded_json =~ "\"workflows\""
    assert encoded_json =~ "\"workflow\": \"workflow_capability_math\""
    assert encoded_json =~ "\"timeout\": 12345"

    assert {:ok, encoded_yaml} = Jidoka.encode_agent(agent, format: :yaml)
    assert encoded_yaml =~ "workflows:"
    assert encoded_yaml =~ "workflow: \"workflow_capability_math\""
  end

  test "imports workflow string entries through available_workflows" do
    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent(
               imported_spec("workflow_string_import_agent",
                 capabilities: %{"workflows" => ["workflow_capability_math"]}
               ),
               available_workflows: [WorkflowCapability.MathWorkflow]
             )

    assert [%{name: "workflow_capability_math"}] = agent.workflows
  end

  test "imports built-in web capabilities without a registry" do
    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent(
               imported_spec("web_import_agent",
                 capabilities: %{"web" => [%{"mode" => "read_only"}]}
               )
             )

    assert [%Jidoka.Web{mode: :read_only}] = agent.web

    assert Enum.map(agent.tool_modules, & &1.name()) == [
             "search_web",
             "read_page",
             "snapshot_url"
           ]

    assert {:ok, encoded_json} = Jidoka.encode_agent(agent, format: :json)
    assert encoded_json =~ "\"web\""
    assert encoded_json =~ "\"mode\": \"read_only\""

    assert {:ok, encoded_yaml} = Jidoka.encode_agent(agent, format: :yaml)
    assert encoded_yaml =~ "web:"
    assert encoded_yaml =~ "mode: \"read_only\""
  end

  test "imports web string entries" do
    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent(
               imported_spec("web_string_import_agent",
                 capabilities: %{"web" => ["search"]}
               )
             )

    assert [%Jidoka.Web{mode: :search}] = agent.web
    assert Enum.map(agent.tool_modules, & &1.name()) == ["search_web"]
  end

  test "imports constrained handoffs and compiles them into generated tool modules" do
    conversation_id = "imported-handoff-#{System.unique_integer([:positive])}"
    peer_id = "billing-import-handoff-peer"
    reset_agent(peer_id)
    assert {:ok, pid} = BillingHandoffSpecialist.start_link(id: peer_id)

    try do
      assert {:ok, %ImportedAgent{} = agent} =
               Jidoka.import_agent(
                 imported_spec("handoff_import_agent",
                   instructions: "You can transfer ownership.",
                   capabilities: %{
                     "handoffs" => [
                       %{
                         "agent" => "billing_specialist",
                         "as" => "billing_transfer",
                         "description" => "Transfer to billing.",
                         "target" => "peer",
                         "peer_id" => peer_id,
                         "forward_context" => %{"mode" => "only", "keys" => ["tenant"]}
                       }
                     ]
                   }
                 ),
                 available_handoffs: [BillingHandoffSpecialist]
               )

      assert [
               %{
                 name: "billing_transfer",
                 target: {:peer, ^peer_id},
                 forward_context: {:only, ["tenant"]}
               }
             ] = agent.handoffs

      assert Enum.map(agent.tool_modules, & &1.name()) == ["billing_transfer"]

      handoff_tool = hd(agent.tool_modules)

      assert {:error, {:handoff, %Jidoka.Handoff{} = handoff}} =
               handoff_tool.run(%{message: "Please continue."}, %{
                 Jidoka.Handoff.context_key() => conversation_id,
                 tenant: "acme",
                 secret: "drop"
               })

      assert handoff.to_agent_id == peer_id
      assert handoff.context == %{tenant: "acme"}
      assert Jidoka.whereis(peer_id) == pid

      assert {:ok, encoded_json} = Jidoka.encode_agent(agent, format: :json)
      assert encoded_json =~ "\"handoffs\""
      assert encoded_json =~ "\"agent\": \"billing_specialist\""

      assert {:ok, encoded_yaml} = Jidoka.encode_agent(agent, format: :yaml)
      assert encoded_yaml =~ "handoffs:"
      assert encoded_yaml =~ "agent: \"billing_specialist\""
    after
      Jidoka.reset_handoff(conversation_id)
      reset_agent(peer_id)
    end
  end

  test "imports handoff string entries through available_handoffs" do
    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent(
               imported_spec("handoff_string_import_agent",
                 capabilities: %{"handoffs" => ["billing_specialist"]}
               ),
               available_handoffs: [BillingHandoffSpecialist]
             )

    assert [%{name: "billing_specialist", target: :auto}] = agent.handoffs
  end

  test "starts an imported agent under the shared runtime" do
    json =
      imported_spec("runtime_agent",
        instructions: "You are a concise assistant.",
        capabilities: %{"tools" => ["add_numbers"], "plugins" => ["math_plugin"]},
        lifecycle: %{"hooks" => %{"before_turn" => ["approval_gate"], "on_interrupt" => ["notify_ops"]}}
      )
      |> Jason.encode!(pretty: true)

    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent(
               json,
               available_tools: [AddNumbers],
               available_plugins: [MathPlugin],
               available_hooks: [InterruptBeforeHook, NotifyOpsHook],
               available_guardrails: [SafePromptGuardrail]
             )

    assert {:ok, pid} = Jidoka.start_agent(agent, id: "imported-agent-test")
    assert Jidoka.whereis("imported-agent-test") == pid
    assert :ok = Jidoka.stop_agent(pid)
  end

  test "merges imported default context into runtime requests" do
    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent(
               imported_spec("runtime_context_agent",
                 context: %{"tenant" => "imported", "channel" => "json"}
               )
             )

    runtime = agent.runtime_module
    runtime_agent = new_runtime_agent(runtime)

    assert {:ok, _agent, {:ai_react_start, params}} =
             runtime.on_before_cmd(
               runtime_agent,
               {:ai_react_start,
                %{
                  query: "hello",
                  request_id: "req-imported-context",
                  tool_context: %{session: "runtime"}
                }}
             )

    assert Jidoka.Context.strip_internal(params.tool_context) == %{
             "tenant" => "imported",
             "channel" => "json",
             session: "runtime"
           }

    assert Jidoka.Context.strip_internal(params.runtime_context) == %{
             "tenant" => "imported",
             "channel" => "json",
             session: "runtime"
           }
  end

  test "imports and round-trips memory settings in constrained imported agent specs" do
    json = """
    {
      "agent": {
        "id": "memory_json_agent"
      },
      "defaults": {
        "model": "fast",
        "instructions": "You are concise."
      },
      "lifecycle": {
        "memory": {
          "mode": "conversation",
          "namespace": "context",
          "context_namespace_key": "session",
          "capture": "conversation",
          "retrieve": {
            "limit": 4
          },
          "inject": "instructions"
        }
      }
    }
    """

    assert {:ok, %ImportedAgent{} = agent} = Jidoka.import_agent(json)

    assert agent.spec.memory == %{
             mode: :conversation,
             namespace: {:context, "session"},
             capture: :conversation,
             retrieve: %{limit: 4},
             inject: :instructions
           }

    assert {:ok, encoded_json} = Jidoka.encode_agent(agent, format: :json)
    assert encoded_json =~ "\"memory\""
    assert encoded_json =~ "\"context_namespace_key\": \"session\""

    assert {:ok, encoded_yaml} = Jidoka.encode_agent(agent, format: :yaml)
    assert encoded_yaml =~ "memory:"
    assert encoded_yaml =~ "namespace: \"context\""
    assert encoded_yaml =~ "context_namespace_key: \"session\""
  end

  test "imported agents retrieve and capture memory across turns" do
    assert {:ok, %ImportedAgent{} = agent} =
             Jidoka.import_agent(%{
               "agent" => %{"id" => "imported_memory_agent"},
               "defaults" => %{"model" => "fast", "instructions" => "You are concise."},
               "lifecycle" => %{
                 "memory" => %{
                   "mode" => "conversation",
                   "namespace" => "context",
                   "context_namespace_key" => "session",
                   "capture" => "conversation",
                   "retrieve" => %{"limit" => 4},
                   "inject" => "context"
                 }
               }
             })

    runtime = agent.runtime_module
    instances = runtime.plugin_instances()
    modules = Enum.map(instances, & &1.module)
    memory_instance = Enum.find(instances, &(&1.module == Jido.Memory.BasicPlugin))
    runtime_agent = new_runtime_agent(runtime)
    session = "imported-memory-#{System.unique_integer([:positive])}"

    assert Jido.Memory.BasicPlugin in modules
    refute Jido.Memory.Plugin in modules
    assert memory_instance.state_key == :__memory__

    {:ok, runtime_agent, _action} =
      runtime.on_before_cmd(
        runtime_agent,
        {:ai_react_start,
         %{
           query: "Remember that I like tea.",
           request_id: "req-imported-memory-1",
           tool_context: %{session: session}
         }}
      )

    runtime_agent =
      Jido.AI.Request.complete_request(runtime_agent, "req-imported-memory-1", "Stored.")

    assert {:ok, runtime_agent, []} =
             runtime.on_after_cmd(
               runtime_agent,
               {:ai_react_start, %{request_id: "req-imported-memory-1"}},
               []
             )

    assert {:ok, _runtime_agent, {:ai_react_start, params}} =
             runtime.on_before_cmd(
               runtime_agent,
               {:ai_react_start,
                %{
                  query: "What do I like?",
                  request_id: "req-imported-memory-2",
                  tool_context: %{session: session}
                }}
             )

    assert %{namespace: _, records: [_user, _assistant]} = params.tool_context[:memory]
  end

  defp reset_agent(agent_id) do
    case Jidoka.whereis(agent_id) do
      nil -> :ok
      pid -> Jidoka.stop_agent(pid)
    end
  end

  defp imported_registry_opts do
    [
      available_tools: [AddNumbers],
      available_skills: [ModuleMathSkill],
      available_plugins: [MetadataOnlyPlugin],
      available_subagents: [ResearchSpecialist],
      available_workflows: [WorkflowCapability.MathWorkflow],
      available_handoffs: [BillingHandoffSpecialist],
      available_hooks: [InjectTenantHook, NormalizeReplyHook, NotifyOpsHook],
      available_guardrails: [SafePromptGuardrail, SafeReplyGuardrail, ApproveLargeMathToolGuardrail]
    ]
  end

  defp imported_spec(id, opts) do
    %{
      "agent" => %{
        "id" => id,
        "context" => Keyword.get(opts, :context, %{})
      },
      "defaults" =>
        %{
          "model" => Keyword.get(opts, :model, "fast"),
          "instructions" => Keyword.get(opts, :instructions, "You are concise."),
          "character" => Keyword.get(opts, :character)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new(),
      "capabilities" => Keyword.get(opts, :capabilities, %{}),
      "lifecycle" => Keyword.get(opts, :lifecycle, %{}),
      "output" => Keyword.get(opts, :output)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
