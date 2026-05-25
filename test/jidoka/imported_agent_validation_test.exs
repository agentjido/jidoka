defmodule JidokaTest.ImportedAgentValidationTest do
  use JidokaTest.Support.Case, async: false

  alias JidokaTest.{
    AddNumbers,
    BillingHandoffSpecialist,
    InjectTenantHook,
    MathPlugin,
    ResearchSpecialist,
    ReviewSpecialist,
    SafePromptGuardrail,
    WorkflowCapability
  }

  test "rejects unsupported imported memory config" do
    assert {:error, reason} =
             Jidoka.import_agent(%{
               "agent" => %{"id" => "bad_memory_agent"},
               "defaults" => %{"model" => "fast", "instructions" => "You are concise."},
               "lifecycle" => %{"memory" => %{"mode" => "semantic"}}
             })

    assert reason =~ "memory mode must be :conversation"
  end

  test "rejects unsupported imported memory modes without interning atoms" do
    mode = "semantic_#{System.unique_integer([:positive])}"

    assert {:error, reason} =
             Jidoka.import_agent(%{
               "agent" => %{"id" => "bad_dynamic_memory_agent"},
               "defaults" => %{"model" => "fast", "instructions" => "You are concise."},
               "lifecycle" => %{"memory" => %{"mode" => mode}}
             })

    assert reason =~ "memory mode must be :conversation"
    assert_raise ArgumentError, fn -> String.to_existing_atom(mode) end
  end

  test "rejects unexpected keys in imported agent specs" do
    assert {:error, reason} =
             Jidoka.import_agent(%{
               "agent" => %{"id" => "bad_agent"},
               "defaults" => %{"model" => "fast", "instructions" => "You are concise."},
               "extra" => true
             })

    assert reason =~ "unrecognized"
  end

  test "rejects flat imported agent specs" do
    assert {:error, reason} =
             Jidoka.import_agent(%{
               "name" => "flat_agent",
               "model" => "fast",
               "system_prompt" => "You are concise."
             })

    assert reason =~ "unrecognized"
    assert reason =~ "agent"
    assert reason =~ "defaults"
  end

  test "rejects unknown bare model aliases in imported agent specs" do
    assert {:error, reason} =
             Jidoka.import_agent(%{
               "agent" => %{"id" => "bad_model_agent"},
               "defaults" => %{"model" => "does_not_exist", "instructions" => "You are concise."}
             })

    assert reason =~ "known alias string"
  end

  test "rejects unknown tool names in imported agent specs" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("bad_tool_agent", capabilities: %{"tools" => ["does_not_exist"]}),
               available_tools: [AddNumbers]
             )

    assert reason =~ "unknown tool"
  end

  test "rejects duplicate tool names in imported agent specs" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("duplicate_tool_agent",
                 capabilities: %{"tools" => ["add_numbers", "add_numbers"]}
               ),
               available_tools: [AddNumbers]
             )

    assert reason =~ "tools must be unique"
  end

  test "rejects unknown plugin names in imported agent specs" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("bad_plugin_agent", capabilities: %{"plugins" => ["does_not_exist"]}),
               available_plugins: [MathPlugin]
             )

    assert reason =~ "unknown plugin"
  end

  test "rejects duplicate plugin names in imported agent specs" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("duplicate_plugin_agent",
                 capabilities: %{"plugins" => ["math_plugin", "math_plugin"]}
               ),
               available_plugins: [MathPlugin]
             )

    assert reason =~ "plugins must be unique"
  end

  test "rejects duplicate hook names within a stage in imported agent specs" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("duplicate_hook_agent",
                 lifecycle: %{"hooks" => %{"before_turn" => ["inject_tenant", "inject_tenant"]}}
               ),
               available_hooks: [InjectTenantHook]
             )

    assert reason =~ "hook names must be unique"
  end

  test "rejects duplicate guardrail names within a stage in imported agent specs" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("duplicate_guardrail_agent",
                 lifecycle: %{"guardrails" => %{"input" => ["safe_prompt", "safe_prompt"]}}
               ),
               available_guardrails: [SafePromptGuardrail]
             )

    assert reason =~ "guardrail names must be unique"
  end

  test "rejects unknown hook names in imported agent specs" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("bad_hook_agent",
                 lifecycle: %{"hooks" => %{"before_turn" => ["does_not_exist"]}}
               ),
               available_hooks: [InjectTenantHook]
             )

    assert reason =~ "unknown hook"
  end

  test "rejects unknown guardrail names in imported agent specs" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("bad_guardrail_agent",
                 lifecycle: %{"guardrails" => %{"input" => ["does_not_exist"]}}
               ),
               available_guardrails: [SafePromptGuardrail]
             )

    assert reason =~ "unknown guardrail"
  end

  test "rejects importing hooks without an available registry" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("missing_hook_registry_agent",
                 lifecycle: %{"hooks" => %{"before_turn" => ["inject_tenant"]}}
               )
             )

    assert reason =~ "available_hooks registry"
  end

  test "rejects importing guardrails without an available registry" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("missing_guardrail_registry_agent",
                 lifecycle: %{"guardrails" => %{"input" => ["safe_prompt"]}}
               )
             )

    assert reason =~ "available_guardrails registry"
  end

  test "rejects imported subagents without an available registry" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("missing_subagent_registry",
                 instructions: "You can delegate.",
                 capabilities: %{"subagents" => [%{"agent" => "research_agent"}]}
               )
             )

    assert reason =~ "available_subagents registry"
  end

  test "rejects imported subagents with duplicate published names" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("duplicate_subagent_import",
                 instructions: "You can delegate.",
                 capabilities: %{
                   "subagents" => [
                     %{"agent" => "research_agent"},
                     %{"agent" => "review_agent", "as" => "research_agent"}
                   ]
                 }
               ),
               available_subagents: [ResearchSpecialist, ReviewSpecialist]
             )

    assert reason =~ "subagent names must be unique"
  end

  test "rejects imported subagents with invalid peer configuration" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("invalid_peer_import",
                 instructions: "You can delegate.",
                 capabilities: %{"subagents" => [%{"agent" => "research_agent", "target" => "peer"}]}
               ),
               available_subagents: [ResearchSpecialist]
             )

    assert reason =~ "subagent target must be"
  end

  test "rejects imported subagents with invalid timeout" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("invalid_subagent_timeout_import",
                 instructions: "You can delegate.",
                 capabilities: %{"subagents" => [%{"agent" => "research_agent", "timeout_ms" => 0}]}
               ),
               available_subagents: [ResearchSpecialist]
             )

    assert reason =~ "subagent timeout must be a positive integer"
  end

  test "rejects imported subagents with invalid forward_context" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("invalid_subagent_forward_context_import",
                 instructions: "You can delegate.",
                 capabilities: %{
                   "subagents" => [
                     %{
                       "agent" => "research_agent",
                       "forward_context" => %{"mode" => "only"}
                     }
                   ]
                 }
               ),
               available_subagents: [ResearchSpecialist]
             )

    assert reason =~ "subagent forward_context keys must be a list"
  end

  test "rejects imported subagents with invalid result mode" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("invalid_subagent_result_import",
                 instructions: "You can delegate.",
                 capabilities: %{"subagents" => [%{"agent" => "research_agent", "result" => "json"}]}
               ),
               available_subagents: [ResearchSpecialist]
             )

    assert reason =~ "subagent result must be :text or :structured"
  end

  test "rejects imported workflows without an available registry" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("missing_workflow_registry",
                 instructions: "You can run workflows.",
                 capabilities: %{"workflows" => ["workflow_capability_math"]}
               )
             )

    assert reason =~ "available_workflows registry"
  end

  test "rejects unknown imported workflows" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("bad_workflow_import",
                 capabilities: %{"workflows" => ["does_not_exist"]}
               ),
               available_workflows: [WorkflowCapability.MathWorkflow]
             )

    assert reason =~ "unknown workflow"
  end

  test "rejects imported workflows with duplicate published names" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("duplicate_workflow_import",
                 capabilities: %{
                   "workflows" => [
                     "workflow_capability_math",
                     %{"workflow" => "workflow_capability_context", "as" => "workflow_capability_math"}
                   ]
                 }
               ),
               available_workflows: [WorkflowCapability.MathWorkflow, WorkflowCapability.ContextWorkflow]
             )

    assert reason =~ "workflow operation names must be unique"
  end

  test "rejects imported workflows with invalid timeout" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("invalid_workflow_timeout_import",
                 capabilities: %{"workflows" => [%{"workflow" => "workflow_capability_math", "timeout" => 0}]}
               ),
               available_workflows: [WorkflowCapability.MathWorkflow]
             )

    assert reason =~ "workflow operation timeout must be a positive integer"
  end

  test "rejects imported workflows with invalid forward_context" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("invalid_workflow_forward_context_import",
                 capabilities: %{
                   "workflows" => [
                     %{
                       "workflow" => "workflow_capability_math",
                       "forward_context" => %{"mode" => "only"}
                     }
                   ]
                 }
               ),
               available_workflows: [WorkflowCapability.MathWorkflow]
             )

    assert reason =~ "workflow operation forward_context keys must be a list"
  end

  test "rejects raw module strings as imported workflow refs" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("raw_workflow_module_import",
                 capabilities: %{"workflows" => ["JidokaTest.WorkflowCapability.MathWorkflow"]}
               ),
               available_workflows: [WorkflowCapability.MathWorkflow]
             )

    assert reason =~ "expected map"
  end

  test "rejects imported web capabilities with unsupported modes" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("invalid_web_import",
                 capabilities: %{"web" => ["interactive"]}
               )
             )

    assert reason =~ "web capability mode must be"
  end

  test "rejects duplicate imported web capabilities" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("duplicate_web_import",
                 capabilities: %{"web" => ["search", "read_only"]}
               )
             )

    assert reason =~ "at most one web capability"
  end

  test "rejects imported handoffs without an available registry" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("missing_handoff_registry",
                 instructions: "You can transfer.",
                 capabilities: %{"handoffs" => ["billing_specialist"]}
               )
             )

    assert reason =~ "available_handoffs registry"
  end

  test "rejects unknown imported handoffs" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("bad_handoff_import",
                 capabilities: %{"handoffs" => ["does_not_exist"]}
               ),
               available_handoffs: [BillingHandoffSpecialist]
             )

    assert reason =~ "unknown handoff"
  end

  test "rejects imported handoffs with duplicate published names" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("duplicate_handoff_import",
                 capabilities: %{
                   "handoffs" => [
                     "billing_specialist",
                     %{"agent" => "billing_specialist", "as" => "billing_specialist"}
                   ]
                 }
               ),
               available_handoffs: [BillingHandoffSpecialist]
             )

    assert reason =~ "handoff names must be unique"
  end

  test "rejects imported handoffs with invalid target and forward_context" do
    assert {:error, target_reason} =
             Jidoka.import_agent(
               imported_spec("invalid_handoff_target_import",
                 capabilities: %{"handoffs" => [%{"agent" => "billing_specialist", "target" => "peer"}]}
               ),
               available_handoffs: [BillingHandoffSpecialist]
             )

    assert target_reason =~ "handoff target must be"

    assert {:error, context_reason} =
             Jidoka.import_agent(
               imported_spec("invalid_handoff_forward_context_import",
                 capabilities: %{
                   "handoffs" => [
                     %{
                       "agent" => "billing_specialist",
                       "forward_context" => %{"mode" => "only"}
                     }
                   ]
                 }
               ),
               available_handoffs: [BillingHandoffSpecialist]
             )

    assert context_reason =~ "subagent forward_context keys must be a list"
  end

  test "rejects raw module strings as imported handoff refs" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("raw_handoff_module_import",
                 capabilities: %{"handoffs" => ["JidokaTest.BillingHandoffSpecialist"]}
               ),
               available_handoffs: [BillingHandoffSpecialist]
             )

    assert reason =~ "expected map"
  end

  test "rejects importing plugins without an available registry" do
    assert {:error, reason} =
             Jidoka.import_agent(
               imported_spec("missing_plugin_registry_agent",
                 capabilities: %{"plugins" => ["math_plugin"]}
               )
             )

    assert reason =~ "available_plugins registry"
  end

  test "rejects importing tools without an available registry" do
    assert {:error, reason} =
             Jidoka.import_agent(imported_spec("missing_registry_agent", capabilities: %{"tools" => ["add_numbers"]}))

    assert reason =~ "available_tools registry"
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
