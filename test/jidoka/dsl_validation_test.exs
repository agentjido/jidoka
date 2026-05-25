defmodule JidokaTest.DslValidationTest do
  use JidokaTest.Support.Case, async: false

  alias JidokaTest.{InjectTenantHook, SafePromptGuardrail}

  test "rejects old keyword opts in favor of the DSL" do
    assert_raise CompileError, ~r/Jidoka.Agent now uses a Spark DSL/, fn ->
      compile_source("""
      defmodule JidokaTest.InvalidKeywordAgent do
        use Jidoka.Agent,
          instructions: "This should fail."
      end
      """)
    end
  end

  test "supports agent :id as the primary entrypoint" do
    module =
      compile_agent("""
      agent :primary_agent do
        model :fast
        instructions "Answer clearly."
        context Zoi.object(%{tenant: Zoi.string() |> Zoi.optional()})
      end
      """)

    assert module.id() == "primary_agent"
    assert module.configured_model() == :fast
    assert module.instructions() == "Answer clearly."
    assert module.context_schema() != nil
  end

  test "keeps deterministic actions outside the agent block" do
    module =
      compile_agent("""
      agent :action_agent do
        instructions "Use deterministic actions when useful."
      end

      tools do
        action JidokaTest.AddNumbers
      end
      """)

    assert module.tools() == [JidokaTest.AddNumbers]
    assert module.tool_names() == ["add_numbers"]
  end

  test "collapses policy into input, operation, and result controls" do
    module =
      compile_agent("""
      agent :controlled_agent do
        instructions "Apply controls."
      end

      controls do
        input JidokaTest.SafePromptGuardrail
        operation JidokaTest.ApproveLargeMathToolGuardrail
        result JidokaTest.SafeReplyGuardrail
      end
      """)

    assert module.input_controls() == [JidokaTest.SafePromptGuardrail]
    assert module.operation_controls() == [JidokaTest.ApproveLargeMathToolGuardrail]
    assert module.result_controls() == [JidokaTest.SafeReplyGuardrail]
  end

  test "supports final V3 operation control matching syntax" do
    module =
      compile_agent("""
      agent :matched_control_agent do
        instructions "Apply matched controls."
      end

      controls do
        operation JidokaTest.BlockOperationControl,
          when: [kind: :subagent]
      end
      """)

    assert [
             %Jidoka.Control.Operation{
               ref: JidokaTest.BlockOperationControl,
               match: %{kind: :subagent}
             }
           ] = module.operation_controls()
  end

  test "supports credential-aware operation control matching syntax" do
    module =
      compile_agent("""
      agent :credential_matched_control_agent do
        instructions "Apply credential-aware controls."
      end

      controls do
        operation JidokaTest.BlockOperationControl,
          when: [
            credential: [
              provider: :github,
              scope: :repo,
              risk: :high,
              confirmation_required: true
            ]
          ]
      end
      """)

    assert [
             %Jidoka.Control.Operation{
               ref: JidokaTest.BlockOperationControl,
               match: %{
                 credential: %{
                   provider: "github",
                   scope: "repo",
                   risk: :high,
                   confirmation_required: true
                 }
               }
             }
           ] = module.operation_controls()
  end

  test "compiles every supported V3 DSL section" do
    module =
      compile_agent("""
      @result_schema Zoi.object(%{summary: Zoi.string()})

      agent :full_section_agent do
        model :fast
        instructions "Exercise the supported DSL sections."
        character :none
        context Zoi.object(%{tenant: Zoi.string() |> Zoi.default("demo")})

        result @result_schema do
          repair(1)
          on_validation_error(:repair)
        end

        schedule :daily_digest do
          cron("0 9 * * *")
          timezone("America/Chicago")
          prompt("Prepare the daily digest.")
          conversation("daily-digest")
          overlap(:skip)
        end
      end

      tools do
        action JidokaTest.AddNumbers
      end

      capabilities do
        plugin JidokaTest.MathPlugin
      end

      lifecycle do
        before_turn JidokaTest.InjectTenantHook
        after_turn JidokaTest.NormalizeReplyHook
        on_interrupt JidokaTest.NotifyOpsHook

        memory do
          mode :conversation
          namespace :per_agent
          capture :conversation
          inject :instructions
          retrieve(limit: 2)
        end

        compaction do
          mode :manual
          strategy :summary
          max_messages(8)
          keep_last(2)
          max_summary_chars(256)
          prompt("Compact older context.")
        end
      end

      controls do
        input JidokaTest.SafePromptGuardrail
        operation JidokaTest.ApproveLargeMathToolGuardrail
        result JidokaTest.SafeReplyGuardrail
      end

      """)

    assert module.id() == "full_section_agent"
    assert module.context().tenant == "demo"
    assert module.result_schema() != nil
    assert module.tool_names() == ["add_numbers", "multiply_numbers"]
    assert module.plugins() == [JidokaTest.MathPlugin]
    assert module.before_turn_hooks() == [JidokaTest.InjectTenantHook]
    assert module.after_turn_hooks() == [JidokaTest.NormalizeReplyHook]
    assert module.interrupt_hooks() == [JidokaTest.NotifyOpsHook]
    assert %{mode: :conversation, namespace: :per_agent} = module.memory()
    assert %{mode: :manual, strategy: :summary, keep_last: 2} = module.compaction()
    assert module.input_controls() == [JidokaTest.SafePromptGuardrail]
    assert module.operation_controls() == [JidokaTest.ApproveLargeMathToolGuardrail]
    assert module.result_controls() == [JidokaTest.SafeReplyGuardrail]

    assert [
             %Jidoka.Schedule{
               id: "full_section_agent:daily_digest",
               cron: "0 9 * * *",
               prompt: "Prepare the daily digest.",
               conversation: "daily-digest"
             }
           ] = module.schedules()
  end

  test "rejects discarded top-level sections" do
    for {section, body} <- [
          {"defaults", "model :fast"},
          {"memory", "mode :conversation"},
          {"skills", "skill \"math-discipline\""},
          {"plugins", "plugin JidokaTest.MathPlugin"},
          {"subagents", "subagent JidokaTest.ResearchSpecialist"},
          {"hooks", "before_turn JidokaTest.InjectTenantHook"},
          {"guardrails", "input JidokaTest.SafePromptGuardrail"},
          {"output", "schema Zoi.object(%{answer: Zoi.string()})"},
          {"schedules", "schedule :daily_digest do\n  cron(\"0 9 * * *\")\n  prompt(\"Daily digest\")\nend"}
        ] do
      assert_compile_error(~r/Top-level `#{section} do .*` is not valid/s, """
      agent :legacy_#{section}_agent do
        instructions "This should fail."
      end

      #{section} do
        #{body}
      end
      """)
    end
  end

  test "rejects ambiguous V3-adjacent syntax" do
    assert_dsl_error(~r/required :id option|agent.*id.*required|missing required.*id/s, """
    agent do
      instructions "This should fail."
    end
    """)

    assert_compile_error(~r/`tool` is not valid.*tools do action/s, """
    agent :tool_in_tools_agent do
      instructions "This should fail."
    end

    tools do
      tool JidokaTest.AddNumbers
    end
    """)

    assert_compile_error(~r/`tool` is not valid.*tools do action/s, """
    agent :tool_in_capabilities_agent do
      instructions "This should fail."
    end

    capabilities do
      tool JidokaTest.AddNumbers
    end
    """)

    assert_compile_error(~r/`input_guardrail` is not valid.*controls do input/s, """
    agent :lifecycle_guardrail_agent do
      instructions "This should fail."
    end

    lifecycle do
      input_guardrail JidokaTest.SafePromptGuardrail
    end
    """)

    assert_compile_error(~r/`tool` is not valid.*tools do action/s, """
    agent :tool_control_agent do
      instructions "This should fail."
    end

    controls do
      tool JidokaTest.SafePromptGuardrail
    end
    """)

    assert_compile_error(~r/Top-level `output do .*` is not valid/s, """
    agent :old_output_agent do
      instructions "This should fail."

      output do
        schema Zoi.object(%{summary: Zoi.string()})
      end
    end
    """)
  end

  test "requires lower snake case agent ids" do
    assert_dsl_error(~r/agent.*id.*lower snake case/s, """
    agent "Bad-ID" do
      instructions "This should fail."
    end
    """)
  end

  test "requires agent ids" do
    assert_dsl_error(~r/agent.*id.*required/s, """
    agent nil do
      instructions "This should fail."
    end
    """)
  end

  test "requires agent.instructions" do
    assert_dsl_error(~r/agent.instructions.*required/s, """
    agent :missing_instructions_agent do
    end
    """)
  end

  test "rejects invalid instructions resolvers" do
    assert_dsl_error(~r/instructions does not support anonymous functions/, """
    agent :invalid_instructions_agent do
      instructions fn _input -> "This should fail." end
    end
    """)
  end

  test "rejects invalid model configuration" do
    assert_dsl_error(~r/invalid model input 123/, """
    agent :invalid_model_agent do
      model 123
      instructions "This should fail."
    end
    """)
  end

  test "rejects non-map agent contexts" do
    assert_dsl_error(~r/agent context must be a Zoi map\/object schema/, """
    agent :invalid_context_schema_agent do
      instructions "This should fail."

      context Zoi.string()
    end
    """)
  end

  test "validates structured result contracts" do
    assert_dsl_error(~r/result schema must be a Zoi object\/map schema/, """
    agent :invalid_output_schema_agent do
      instructions "This should fail."

      result Zoi.string()
    end
    """)

    assert_dsl_error(~r/result repair must be a non-negative integer/, """
    agent :invalid_output_retries_agent do
      instructions "This should fail."

      result Zoi.object(%{summary: Zoi.string()}), repair: -1
    end
    """)

    assert_dsl_error(~r/Zoi object\/map schema in the Elixir DSL/, """
    agent :json_schema_output_agent do
      instructions "This should fail."

      result %{"type" => "object", "properties" => %{"summary" => %{"type" => "string"}}}
    end
    """)
  end

  test "validates memory lifecycle configuration" do
    assert_dsl_error(~r/memory namespace must be :per_agent, :shared with shared_namespace/, """
    agent :invalid_memory_namespace_agent do
      instructions "This should fail."
    end

    lifecycle do
      memory do
        namespace :shared
      end
    end
    """)

    assert_dsl_error(~r/shared_namespace is only valid when namespace is :shared/, """
    agent :invalid_shared_namespace_agent do
      instructions "This should fail."
    end

    lifecycle do
      memory do
        namespace :per_agent
        shared_namespace "wrong"
      end
    end
    """)

    assert_dsl_error(~r/memory context namespace key is not declared/, """
    agent :invalid_memory_context_key_agent do
      instructions "This should fail."

      context Zoi.object(%{tenant: Zoi.string() |> Zoi.optional()})
    end

    lifecycle do
      memory do
        namespace {:context, :session}
      end
    end
    """)
  end

  test "validates compaction lifecycle configuration" do
    assert_dsl_error(~r/keep_last must be less than max_messages/, """
    agent :invalid_compaction_agent do
      instructions "This should fail."
    end

    lifecycle do
      compaction do
        max_messages(4)
        keep_last(4)
      end
    end
    """)
  end

  test "validates schedule configuration" do
    assert_dsl_error(~r/prompt.*required|required.*prompt/s, """
    agent :invalid_schedule_agent do
      instructions "This should fail."

      schedule :missing_prompt do
        cron("0 9 * * *")
      end
    end
    """)
  end

  test "rejects duplicate action names across operation sources" do
    assert_dsl_error(~r/duplicate operation names.*multiply_numbers/s, """
    agent :duplicate_capability_agent do
      instructions "This should fail."
    end

    tools do
      action JidokaTest.MultiplyNumbers
    end

    capabilities do
      plugin JidokaTest.MathPlugin
    end
    """)
  end

  test "rejects duplicate lifecycle and control refs within stages" do
    assert_dsl_error(~r/hook .*defined more than once/, """
    agent :duplicate_hook_agent do
      instructions "This should fail."
    end

    lifecycle do
      before_turn JidokaTest.InjectTenantHook
      before_turn JidokaTest.InjectTenantHook
    end
    """)

    assert_dsl_error(~r/control .*defined more than once/, """
    agent :duplicate_control_agent do
      instructions "This should fail."
    end

    controls do
      input JidokaTest.SafePromptGuardrail
      input JidokaTest.SafePromptGuardrail
    end
    """)
  end

  test "control validation errors point to the controls section" do
    error =
      capture_dsl_error("""
      agent :source_aware_controls_agent do
        instructions "This should fail."
      end

      controls do
        input JidokaTest.SafePromptGuardrail
        input JidokaTest.SafePromptGuardrail
      end
      """)

    assert error.path == [:controls, :input]
    assert error.message =~ "control JidokaTest.SafePromptGuardrail is defined more than once"
    assert error.message =~ "Fix: Remove the duplicate control declaration from the input stage."
  end

  test "rejects invalid action modules" do
    assert_dsl_error(~r/not a valid Jidoka action/, """
    agent :invalid_tool_agent do
      instructions "This should fail."
    end

    tools do
      action String
    end
    """)
  end

  test "requires actions and workflow capabilities to reference named modules" do
    assert_dsl_error(~r/action :load_ticket could not be loaded/, """
    agent :inline_action_agent do
      instructions "This should fail."
    end

    tools do
      action :load_ticket
    end
    """)

    assert_dsl_error(~r/workflow :daily_digest is not a valid Jidoka workflow/, """
    agent :inline_workflow_agent do
      instructions "This should fail."
    end

    capabilities do
      workflow :daily_digest
    end
    """)
  end

  test "rejects invalid request hook stages" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Agent.prepare_chat_opts([hooks: [bogus: InjectTenantHook]], nil)

    assert error.field == :hooks
    assert error.details.reason == :invalid_hook_stage
    assert error.details.stage == :bogus
  end

  test "rejects invalid request hook refs" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Agent.prepare_chat_opts([hooks: [before_turn: String]], nil)

    assert error.field == :hooks
    assert error.details.reason == :invalid_hook
    assert error.details.stage == :before_turn
    assert error.message =~ "not a valid Jidoka hook"
  end

  test "rejects invalid request control stages" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Agent.prepare_chat_opts([controls: [bogus: SafePromptGuardrail]], nil)

    assert error.field == :controls
    assert error.details.reason == :invalid_control_stage
    assert error.details.stage == :bogus
  end

  test "rejects invalid request control refs" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Agent.prepare_chat_opts([controls: [input: String]], nil)

    assert error.field == :controls
    assert error.details.reason == :invalid_control
    assert error.details.stage == :input
    assert error.message =~ "not a valid Jidoka control"
  end

  test "rejects NimbleOptions schemas in Jidoka.Action" do
    assert_raise CompileError, ~r/must use a Zoi schema for schema\/0/, fn ->
      compile_source("""
      defmodule JidokaTest.NimbleSchemaTool do
        use Jidoka.Action,
          schema: [a: [type: :integer, required: true]]

        @impl true
        def run(params, _context), do: {:ok, params}
      end
      """)
    end
  end

  test "rejects raw JSON Schema maps in Jidoka.Action" do
    assert_raise CompileError, ~r/must use a Zoi schema for schema\/0/, fn ->
      compile_source("""
      defmodule JidokaTest.JsonSchemaTool do
        use Jidoka.Action,
          schema: %{"type" => "object", "properties" => %{"a" => %{"type" => "integer"}}}

        @impl true
        def run(params, _context), do: {:ok, params}
      end
      """)
    end
  end

  defp assert_dsl_error(pattern, body) do
    module = Module.concat(JidokaTest.DynamicDsl, "Agent#{System.unique_integer([:positive])}")

    source = """
    defmodule #{inspect(module)} do
      use Jidoka.Agent

      #{body}
    end
    """

    assert_raise Spark.Error.DslError, pattern, fn ->
      compile_source(source)
    end
  end

  defp capture_dsl_error(body) do
    module = Module.concat(JidokaTest.DynamicDsl, "Agent#{System.unique_integer([:positive])}")

    source = """
    defmodule #{inspect(module)} do
      use Jidoka.Agent

      #{body}
    end
    """

    assert_raise Spark.Error.DslError, fn ->
      compile_source(source)
    end
  end

  defp assert_compile_error(pattern, body) do
    module = Module.concat(JidokaTest.DynamicDsl, "Agent#{System.unique_integer([:positive])}")

    source = """
    defmodule #{inspect(module)} do
      use Jidoka.Agent

      #{body}
    end
    """

    assert_raise CompileError, pattern, fn ->
      compile_source(source)
    end
  end

  defp compile_agent(body) do
    module = Module.concat(JidokaTest.DynamicDsl, "Agent#{System.unique_integer([:positive])}")

    source = """
    defmodule #{inspect(module)} do
      use Jidoka.Agent

      #{body}
    end
    """

    compile_source(source)
    module
  end

  defp compile_source(source), do: Code.compile_string(source)
end
