defmodule Jidoka.Agent.DslTest do
  use ExUnit.Case, async: false

  test "rejects old keyword opts in favor of the Spark DSL" do
    suffix = System.unique_integer([:positive])

    assert_raise CompileError, ~r/Jidoka.Agent now uses a Spark DSL/, fn ->
      Code.compile_string("""
      defmodule JidokaTest.InvalidKeywordAgent#{suffix} do
        use Jidoka.Agent, id: "bad_agent"
      end
      """)
    end
  end

  test "compiles the minimal agent and tools DSL into an agent spec" do
    suffix = System.unique_integer([:positive])
    agent_module = Module.concat(JidokaTest, "CompiledDslAgent#{suffix}")
    agent_id = "compiled_agent_#{suffix}"
    tool_name = "compiled_tool_#{suffix}"

    Code.compile_string("""
    defmodule JidokaTest.CompiledDslAction#{suffix} do
      use Jidoka.Action,
        name: "compiled_tool_#{suffix}",
        description: "Compiled DSL test action.",
        schema: Zoi.object(%{})

      @impl true
      def run(_params, _context), do: {:ok, %{ok: true}}
    end

    defmodule JidokaTest.CompiledDslAgent#{suffix} do
      use Jidoka.Agent

      agent :compiled_agent_#{suffix} do
        model %{provider: :test, id: "model"}
        generation %{temperature: 0.1, max_tokens: 128}
        instructions "Use the compiled tool."
        context Zoi.object(%{})
      end

      tools do
        action JidokaTest.CompiledDslAction#{suffix}
      end
    end
    """)

    assert agent_module.__jidoka_agent__().id == agent_id
    assert agent_module.__jidoka_agent__().context_schema
    assert Jidoka.Config.model_ref(agent_module.__jidoka_agent__().model) == "test:model"
    assert agent_module.spec().generation.params == %{temperature: 0.1, max_tokens: 128}

    assert [%Jidoka.Agent.Spec.Operation{name: ^tool_name}] =
             agent_module.spec().operations

    assert agent_module.spec().metadata["context_schema?"]

    assert %Jido.Agent{name: ^agent_id} = agent_module.new()
  end

  test "supports a bare agent declaration with default instructions and no tools" do
    suffix = System.unique_integer([:positive])
    agent_module = Module.concat(JidokaTest, "BareDslAgent#{suffix}")
    agent_id = "bare_agent_#{suffix}"

    Code.compile_string("""
    defmodule JidokaTest.BareDslAgent#{suffix} do
      use Jidoka.Agent

      agent :bare_agent_#{suffix}
    end
    """)

    assert agent_module.__jidoka_agent__().id == agent_id
    assert agent_module.__jidoka_agent__().instructions == Jidoka.Agent.default_instructions()

    assert Jidoka.Config.model_ref(agent_module.__jidoka_agent__().model) ==
             Jidoka.Config.model_ref(Jidoka.Config.default_model())

    assert agent_module.__jidoka_agent__().actions == []

    spec = agent_module.spec()
    assert spec.id == agent_id
    assert spec.instructions == Jidoka.Agent.default_instructions()

    assert Jidoka.Config.model_ref(spec.model) ==
             Jidoka.Config.model_ref(Jidoka.Config.default_model())

    assert spec.operations == []

    llm = fn _intent, _journal ->
      {:ok, %{type: :final, content: "hello"}}
    end

    assert {:ok, "hello"} = agent_module.chat("Say hello", llm: llm)
  end

  test "uses the configured default model for bare agents" do
    previous_default = Application.get_env(:jidoka, :default_model)

    on_exit(fn ->
      if is_nil(previous_default) do
        Application.delete_env(:jidoka, :default_model)
      else
        Application.put_env(:jidoka, :default_model, previous_default)
      end
    end)

    Application.put_env(:jidoka, :default_model, %{provider: :test, id: "configured-default"})

    suffix = System.unique_integer([:positive])
    agent_module = Module.concat(JidokaTest, "ConfiguredDefaultDslAgent#{suffix}")

    Code.compile_string("""
    defmodule JidokaTest.ConfiguredDefaultDslAgent#{suffix} do
      use Jidoka.Agent

      agent :configured_default_agent_#{suffix}
    end
    """)

    assert Jidoka.Config.model_ref(agent_module.__jidoka_agent__().model) ==
             "test:configured-default"

    assert Jidoka.Config.model_ref(agent_module.spec().model) == "test:configured-default"
  end

  test "rejects model aliases in favor of explicit model data" do
    suffix = System.unique_integer([:positive])

    assert_raise Spark.Error.DslError, ~r/must be a valid ReqLLM\/LLMDB model input/, fn ->
      Code.compile_string("""
      defmodule JidokaTest.AliasModelDslAgent#{suffix} do
        use Jidoka.Agent

        agent :alias_model_agent_#{suffix} do
          model :fast
        end
      end
      """)
    end
  end

  test "rejects modules without an agent declaration" do
    suffix = System.unique_integer([:positive])

    assert_raise ArgumentError, ~r/must define `agent :id do ... end`/, fn ->
      Code.compile_string("""
      defmodule JidokaTest.MissingAgentDslAgent#{suffix} do
        use Jidoka.Agent
      end
      """)
    end
  end

  test "rejects invalid agent ids, empty instructions, and invalid generation" do
    suffix = System.unique_integer([:positive])

    assert_raise ArgumentError, ~r/agent id must be lower snake case/, fn ->
      Code.compile_string("""
      defmodule JidokaTest.InvalidIdDslAgent#{suffix} do
        use Jidoka.Agent

        agent :InvalidId
      end
      """)
    end

    assert_raise ArgumentError, ~r/instructions must be a non-empty string/, fn ->
      Code.compile_string("""
      defmodule JidokaTest.InvalidInstructionsDslAgent#{suffix} do
        use Jidoka.Agent

        agent :invalid_instructions_agent_#{suffix} do
          instructions "   "
        end
      end
      """)
    end

    assert_raise Spark.Error.DslError, ~r/generation/, fn ->
      Code.compile_string("""
      defmodule JidokaTest.InvalidGenerationDslAgent#{suffix} do
        use Jidoka.Agent

        agent :invalid_generation_agent_#{suffix} do
          generation "not generation data"
        end
      end
      """)
    end
  end

  test "rejects duplicate action tool names" do
    suffix = System.unique_integer([:positive])

    assert_raise Spark.Error.DslError, ~r/defined more than once/, fn ->
      Code.compile_string("""
      defmodule JidokaTest.DuplicateDslAction#{suffix} do
        use Jidoka.Action,
          name: "duplicate_tool_#{suffix}",
          description: "Duplicate DSL test action.",
          schema: Zoi.object(%{})

        @impl true
        def run(_params, _context), do: {:ok, %{ok: true}}
      end

      defmodule JidokaTest.DuplicateDslAgent#{suffix} do
        use Jidoka.Agent

        agent :duplicate_agent_#{suffix} do
          instructions "This should fail."
        end

        tools do
          action JidokaTest.DuplicateDslAction#{suffix}
          action JidokaTest.DuplicateDslAction#{suffix}
        end
      end
      """)
    end
  end

  test "rejects action modules that do not expose Jido tool metadata" do
    suffix = System.unique_integer([:positive])

    assert_raise Spark.Error.DslError, ~r/must expose `to_tool\/0`/, fn ->
      Code.compile_string("""
      defmodule JidokaTest.InvalidActionDslAgent#{suffix} do
        use Jidoka.Agent

        agent :invalid_action_agent_#{suffix}

        tools do
          action String
        end
      end
      """)
    end
  end
end
