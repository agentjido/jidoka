defmodule Jidoka.Agent.DslTest do
  use ExUnit.Case, async: false

  defmodule FakeAshJidoTools do
    @moduledoc false

    def actions(resource) do
      if Code.ensure_loaded?(resource) and
           function_exported?(resource, :__jidoka_ash_jido_actions__, 0) do
        resource.__jidoka_ash_jido_actions__()
      else
        []
      end
    end
  end

  defmodule FakeBrowserReadAction do
    @moduledoc false

    def run(params, _context), do: {:ok, %{content: "Read complete.", params: params}}
  end

  setup do
    previous = Application.get_env(:jidoka, :ash_jido_tools)
    Application.put_env(:jidoka, :ash_jido_tools, FakeAshJidoTools)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:jidoka, :ash_jido_tools)
      else
        Application.put_env(:jidoka, :ash_jido_tools, previous)
      end
    end)
  end

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

    defmodule JidokaTest.CompiledDslControl#{suffix} do
      use Jidoka.Control, name: "compiled_control_#{suffix}"

      @impl true
      def call(_operation), do: :cont
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

      controls do
        max_turns 5
        timeout 2_000
        input JidokaTest.CompiledDslControl#{suffix}
        output JidokaTest.CompiledDslControl#{suffix}

        operation JidokaTest.CompiledDslControl#{suffix},
          when: [kind: :action, name: :compiled_tool_#{suffix}]
      end
    end
    """)

    assert agent_module.__jidoka_agent__().id == agent_id
    assert agent_module.__jidoka_agent_id__() == agent_id
    assert agent_module.__jidoka_agent__().context_schema
    assert Jidoka.Config.model_ref(agent_module.__jidoka_agent__().model) == "test:model"
    assert agent_module.spec().generation.params == %{temperature: 0.1, max_tokens: 128}

    assert [%Jidoka.Agent.Spec.Operation{name: ^tool_name}] =
             agent_module.spec().operations

    assert [
             %Jidoka.Agent.Spec.Controls.Input{
               control: control_module,
               metadata: %{}
             }
           ] = agent_module.spec().controls.inputs

    assert agent_module.spec().controls.max_turns == 5
    assert agent_module.spec().controls.timeout_ms == 2_000

    assert [
             %Jidoka.Agent.Spec.Controls.Operation{
               control: ^control_module,
               match: %{kind: :action, name: ^tool_name}
             }
           ] = agent_module.spec().controls.operations

    assert [
             %Jidoka.Agent.Spec.Controls.Output{
               control: ^control_module,
               metadata: %{}
             }
           ] = agent_module.spec().controls.outputs

    assert control_module.name() == "compiled_control_#{suffix}"

    assert agent_module.spec().metadata["context_schema?"]

    assert %Jido.Agent{name: ^agent_id} = agent_module.new()

    assert %{
             id: ^agent_id,
             start: {Jido.AgentServer, :start_link, [child_opts]},
             type: :worker
           } = agent_module.child_spec()

    assert Keyword.fetch!(child_opts, :agent) == agent_module
    assert Keyword.fetch!(child_opts, :jido) == Jidoka.Jido
    assert Keyword.fetch!(child_opts, :id) == agent_id

    assert %{
             id: "custom_agent_child",
             start: {Jido.AgentServer, :start_link, [custom_child_opts]}
           } =
             agent_module.child_spec(
               id: "custom_agent_child",
               jido: Jidoka.Agent.DslTest.FakeJido
             )

    assert Keyword.fetch!(custom_child_opts, :agent) == agent_module
    assert Keyword.fetch!(custom_child_opts, :jido) == Jidoka.Agent.DslTest.FakeJido
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
    assert spec.controls.operations == []

    llm = fn _intent, _journal ->
      {:ok, %{type: :final, content: "hello"}}
    end

    assert {:ok, "hello"} = agent_module.chat("Say hello", llm: llm)
  end

  test "compiles ash_resource, browser, and catalog tool sources into operation data" do
    suffix = System.unique_integer([:positive])
    agent_module = Module.concat(JidokaTest, "SourceDslAgent#{suffix}")

    Code.compile_string("""
    defmodule JidokaTest.SourceAshReadAction#{suffix} do
      use Jidoka.Action,
        name: "read",
        description: "Generated AshJido read action.",
        schema: Zoi.object(%{})

      @impl true
      def run(_params, _context), do: {:ok, %{ok: true}}
    end

    defmodule JidokaTest.SourceAshCreateAction#{suffix} do
      use Jidoka.Action,
        name: "create",
        description: "Generated AshJido create action.",
        schema: Zoi.object(%{})

      @impl true
      def run(_params, _context), do: {:ok, %{ok: true}}
    end

    defmodule JidokaTest.SourceAshResource#{suffix} do
      def __jidoka_ash_jido_actions__ do
        [
          JidokaTest.SourceAshReadAction#{suffix},
          JidokaTest.SourceAshCreateAction#{suffix}
        ]
      end
    end

    defmodule JidokaTest.SourceDslControl#{suffix} do
      use Jidoka.Control, name: "source_control_#{suffix}"

      @impl true
      def call(_operation), do: :cont
    end

    defmodule JidokaTest.SourceDslAgent#{suffix} do
      use Jidoka.Agent

      agent :source_agent_#{suffix} do
        model %{provider: :test, id: "model"}
        instructions "Use declared tool sources when appropriate."
      end

      tools do
        ash_resource JidokaTest.SourceAshResource#{suffix},
          actions: [:read, :create]

        browser :docs,
          allow: ["https://docs.example.com"],
          mode: :read_only

        catalog :support_ops,
          via: :connect,
          providers: [:github],
          max_results: 8
      end

      controls do
        operation JidokaTest.SourceDslControl#{suffix}, when: [kind: :browser]
        operation JidokaTest.SourceDslControl#{suffix}, when: [kind: :catalog]
        operation JidokaTest.SourceDslControl#{suffix}, when: [kind: :ash_resource]
      end
    end
    """)

    operations = Map.new(agent_module.spec().operations, &{&1.name, &1})
    ash_resource = "JidokaTest.SourceAshResource#{suffix}"

    assert %Jidoka.Agent.Spec.Operation{
             metadata: %{
               "kind" => "ash_resource",
               "source" => "ash_resource",
               "resource" => ^ash_resource,
               "action" => "read"
             }
           } = operations["read"]

    assert %Jidoka.Agent.Spec.Operation{
             metadata: %{
               "kind" => "ash_resource",
               "source" => "ash_resource",
               "resource" => ^ash_resource,
               "action" => "create"
             }
           } = operations["create"]

    assert %Jidoka.Agent.Spec.Operation{
             name: "read_page",
             metadata: %{
               "kind" => "browser",
               "source" => "browser",
               "browser" => "docs",
               "mode" => "read_only",
               "allow" => ["https://docs.example.com"]
             }
           } = operations["read_page"]

    assert %Jidoka.Agent.Spec.Operation{metadata: %{"kind" => "browser"}} =
             operations["search_web"]

    assert %Jidoka.Agent.Spec.Operation{metadata: %{"kind" => "browser"}} =
             operations["snapshot_url"]

    assert %Jidoka.Agent.Spec.Operation{
             metadata: %{
               "kind" => "catalog",
               "source" => "catalog",
               "catalog" => "support_ops",
               "via" => "connect",
               "providers" => ["github"],
               "max_results" => 8
             }
           } = operations["catalog_support_ops"]

    assert Jidoka.Browser.Tools.ReadPage in agent_module.__jidoka_agent__().actions

    assert [
             %{
               "source" => "ash_resource",
               "actions" => ["read", "create"]
             },
             %{"source" => "browser", "name" => "docs"},
             %{"source" => "catalog", "name" => "support_ops"}
           ] = agent_module.spec().metadata["tool_sources"]
  end

  test "records unresolved ash_resource sources without publishing fake operations" do
    suffix = System.unique_integer([:positive])
    agent_module = Module.concat(JidokaTest, "UnresolvedAshDslAgent#{suffix}")

    Code.compile_string("""
    defmodule JidokaTest.UnresolvedAshResource#{suffix} do
    end

    defmodule JidokaTest.UnresolvedAshDslAgent#{suffix} do
      use Jidoka.Agent

      agent :unresolved_ash_agent_#{suffix} do
        model %{provider: :test, id: "model"}
      end

      tools do
        ash_resource JidokaTest.UnresolvedAshResource#{suffix}
      end
    end
    """)

    assert agent_module.spec().operations == []
    ash_resource = "JidokaTest.UnresolvedAshResource#{suffix}"

    assert [
             %{
               "source" => "ash_resource",
               "resource" => ^ash_resource,
               "actions" => [],
               "expanded?" => false
             }
           ] = agent_module.spec().metadata["tool_sources"]
  end

  test "normalizes tool source defaults and filters" do
    suffix = System.unique_integer([:positive])
    agent_module = Module.concat(JidokaTest, "ToolSourceDefaultsAgent#{suffix}")

    Code.compile_string("""
    defmodule JidokaTest.ToolSourceDefaultsReadAction#{suffix} do
      use Jidoka.Action,
        name: "read",
        description: "Generated AshJido read action.",
        schema: Zoi.object(%{})

      @impl true
      def run(_params, _context), do: {:ok, %{ok: true}}
    end

    defmodule JidokaTest.ToolSourceDefaultsResource#{suffix} do
      def __jidoka_ash_jido_actions__, do: [JidokaTest.ToolSourceDefaultsReadAction#{suffix}]
    end

    defmodule JidokaTest.ToolSourceDefaultsCatalog#{suffix} do
    end

    defmodule JidokaTest.ToolSourceDefaultsAgent#{suffix} do
      use Jidoka.Agent

      agent :tool_source_defaults_agent_#{suffix} do
        model %{provider: :test, id: "model"}
      end

      tools do
        ash_resource JidokaTest.ToolSourceDefaultsResource#{suffix}, actions: :read
        browser :web

        catalog :ops,
          via: {:module, JidokaTest.ToolSourceDefaultsCatalog#{suffix}},
          only: [:lookup],
          except: :delete,
          metadata: %{risk: "low"}
      end
    end
    """)

    operations = Map.new(agent_module.spec().operations, &{&1.name, &1})

    assert %Jidoka.Agent.Spec.Operation{
             name: "read",
             metadata: %{"kind" => "ash_resource", "action" => "read"}
           } = operations["read"]

    assert %Jidoka.Agent.Spec.Operation{
             metadata: %{"mode" => "read_only", "allow" => []}
           } = operations["read_page"]

    assert %Jidoka.Agent.Spec.Operation{metadata: metadata} = operations["catalog_ops"]

    assert %{"kind" => "catalog", "only" => ["lookup"], "except" => ["delete"], "via" => via} =
             metadata

    assert metadata[:risk] == "low"
    assert via == "{:module, JidokaTest.ToolSourceDefaultsCatalog#{suffix}}"
  end

  test "default runtime routes browser tool sources through the Jido action path" do
    suffix = System.unique_integer([:positive])
    agent_module = Module.concat(JidokaTest, "BrowserRuntimeMissingAgent#{suffix}")
    previous_browser_actions = Application.get_env(:jidoka, :browser_actions)

    Application.put_env(:jidoka, :browser_actions, %{
      read_page: FakeBrowserReadAction
    })

    on_exit(fn ->
      if is_nil(previous_browser_actions) do
        Application.delete_env(:jidoka, :browser_actions)
      else
        Application.put_env(:jidoka, :browser_actions, previous_browser_actions)
      end
    end)

    Code.compile_string("""
    defmodule JidokaTest.BrowserRuntimeMissingAgent#{suffix} do
      use Jidoka.Agent

      agent :browser_runtime_missing_agent_#{suffix} do
        model %{provider: :test, id: "model"}
      end

      tools do
        browser :docs
      end
    end
    """)

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    llm = fn _intent, _journal ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "read_page",
             arguments: %{"url" => "https://example.com"}
           }}

        _calls ->
          {:ok, %{type: :final, content: "Read complete."}}
      end
    end

    assert {:ok, "Read complete."} = agent_module.chat("Read the docs", llm: llm)
  end

  test "compiles a structured result schema from the agent DSL" do
    suffix = System.unique_integer([:positive])
    agent_module = Module.concat(JidokaTest, "StructuredResultDslAgent#{suffix}")

    Code.compile_string("""
    defmodule JidokaTest.StructuredResultDslAgent#{suffix} do
      use Jidoka.Agent

      agent :structured_result_agent_#{suffix} do
        model %{provider: :test, id: "model"}

        result schema: Zoi.object(%{
                 answer: Zoi.string(),
                 score: Zoi.integer()
               }),
               max_repairs: 2
      end
    end
    """)

    assert %Jidoka.Agent.Spec.Result{max_repairs: 2} = result = agent_module.spec().result

    assert {:ok, %{answer: "Ada", score: 10}} =
             Jidoka.Agent.Spec.Result.validate(result, %{"answer" => "Ada", "score" => 10})
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

  test "rejects duplicate operation names across tool sources" do
    suffix = System.unique_integer([:positive])

    assert_raise Spark.Error.DslError, ~r/tool "read_page" is defined more than once/, fn ->
      Code.compile_string("""
      defmodule JidokaTest.DuplicateSourceAction#{suffix} do
        use Jidoka.Action,
          name: "read_page",
          description: "Duplicate source action.",
          schema: Zoi.object(%{})

        @impl true
        def run(_params, _context), do: {:ok, %{ok: true}}
      end

      defmodule JidokaTest.DuplicateSourceAgent#{suffix} do
        use Jidoka.Agent

        agent :duplicate_source_agent_#{suffix}

        tools do
          action JidokaTest.DuplicateSourceAction#{suffix}
          browser :docs
        end
      end
      """)
    end
  end

  test "rejects invalid tool source names" do
    suffix = System.unique_integer([:positive])

    assert_raise Spark.Error.DslError, ~r/browser name must be lower snake case/, fn ->
      Code.compile_string("""
      defmodule JidokaTest.InvalidBrowserNameAgent#{suffix} do
        use Jidoka.Agent

        agent :invalid_browser_name_agent_#{suffix}

        tools do
          browser "Docs"
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

  test "rejects invalid operation controls" do
    suffix = System.unique_integer([:positive])

    assert_raise Spark.Error.DslError, ~r/must expose `name\/0` and `call\/1`/, fn ->
      Code.compile_string("""
      defmodule JidokaTest.InvalidControlDslAgent#{suffix} do
        use Jidoka.Agent

        agent :invalid_control_agent_#{suffix}

        controls do
          operation String, when: [kind: :action, name: :lookup]
        end
      end
      """)
    end

    assert_raise Spark.Error.DslError, ~r/invalid operation control/, fn ->
      Code.compile_string("""
      defmodule JidokaTest.BadControlMatch#{suffix} do
        use Jidoka.Control, name: "bad_control_match_#{suffix}"

        @impl true
        def call(_operation), do: :cont
      end

      defmodule JidokaTest.BadControlMatchAgent#{suffix} do
        use Jidoka.Agent

        agent :bad_control_match_agent_#{suffix}

        controls do
          operation JidokaTest.BadControlMatch#{suffix},
            when: [kind: :unknown, name: :lookup]
        end
      end
      """)
    end
  end
end
