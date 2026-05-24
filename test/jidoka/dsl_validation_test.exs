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

  test "collapses guardrail-facing policy into controls" do
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

    assert module.input_guardrails() == [JidokaTest.SafePromptGuardrail]
    assert module.tool_guardrails() == [JidokaTest.ApproveLargeMathToolGuardrail]
    assert module.output_guardrails() == [JidokaTest.SafeReplyGuardrail]
  end

  test "rejects legacy top-level sections" do
    for {section, body} <- [
          {"memory", "mode :conversation"},
          {"skills", "skill \"math-discipline\""},
          {"plugins", "plugin JidokaTest.MathPlugin"},
          {"subagents", "subagent JidokaTest.ResearchSpecialist"},
          {"hooks", "before_turn JidokaTest.InjectTenantHook"},
          {"guardrails", "input JidokaTest.SafePromptGuardrail"}
        ] do
      assert_dsl_error(~r/Top-level `#{section} do .*` is not valid/s, """
      agent :legacy_#{section}_agent do
        instructions "This should fail."
      end

      #{section} do
        #{body}
      end
      """)
    end
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

  test "rejects duplicate capability names across sources" do
    assert_dsl_error(~r/duplicate tool names.*multiply_numbers/s, """
    agent :duplicate_capability_agent do
      instructions "This should fail."
    end

    capabilities do
      tool JidokaTest.MultiplyNumbers
      plugin JidokaTest.MathPlugin
    end
    """)
  end

  test "rejects duplicate lifecycle refs within stages" do
    assert_dsl_error(~r/hook .*defined more than once/, """
    agent :duplicate_hook_agent do
      instructions "This should fail."
    end

    lifecycle do
      before_turn JidokaTest.InjectTenantHook
      before_turn JidokaTest.InjectTenantHook
    end
    """)

    assert_dsl_error(~r/guardrail .*defined more than once/, """
    agent :duplicate_guardrail_agent do
      instructions "This should fail."
    end

    lifecycle do
      input_guardrail JidokaTest.SafePromptGuardrail
      input_guardrail JidokaTest.SafePromptGuardrail
    end
    """)
  end

  test "rejects invalid capability modules" do
    assert_dsl_error(~r/not a valid Jidoka tool/, """
    agent :invalid_tool_agent do
      instructions "This should fail."
    end

    capabilities do
      tool String
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

  test "rejects invalid request guardrail stages" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Agent.prepare_chat_opts([guardrails: [bogus: SafePromptGuardrail]], nil)

    assert error.field == :guardrails
    assert error.details.reason == :invalid_guardrail_stage
    assert error.details.stage == :bogus
  end

  test "rejects invalid request guardrail refs" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Agent.prepare_chat_opts([guardrails: [input: String]], nil)

    assert error.field == :guardrails
    assert error.details.reason == :invalid_guardrail
    assert error.details.stage == :input
    assert error.message =~ "not a valid Jidoka guardrail"
  end

  test "rejects NimbleOptions schemas in Jidoka.Tool" do
    assert_raise CompileError, ~r/must use a Zoi schema for schema\/0/, fn ->
      compile_source("""
      defmodule JidokaTest.NimbleSchemaTool do
        use Jidoka.Tool,
          schema: [a: [type: :integer, required: true]]

        @impl true
        def run(params, _context), do: {:ok, params}
      end
      """)
    end
  end

  test "rejects raw JSON Schema maps in Jidoka.Tool" do
    assert_raise CompileError, ~r/must use a Zoi schema for schema\/0/, fn ->
      compile_source("""
      defmodule JidokaTest.JsonSchemaTool do
        use Jidoka.Tool,
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
