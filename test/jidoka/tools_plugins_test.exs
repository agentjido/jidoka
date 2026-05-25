defmodule JidokaTest.ToolsPluginsTest do
  use JidokaTest.Support.Case, async: false

  alias JidokaTest.{AddNumbers, FailingAction, MathPlugin, MultiplyNumbers, PluginAgent, ToolAgent}

  test "wraps Jido.Action with Jidoka.Action defaults" do
    assert AddNumbers.name() == "add_numbers"
    assert AddNumbers.description() == "Adds two integers together."
    assert Jidoka.Action.name(AddNumbers) == {:ok, "add_numbers"}
    assert Jidoka.Action.names([AddNumbers, MultiplyNumbers]) == {:ok, ["add_numbers", "multiply_numbers"]}

    assert %Zoi.Types.Map{} = AddNumbers.schema()

    assert %{
             name: "add_numbers",
             description: "Adds two integers together.",
             parameters_schema: %{
               type: :object,
               required: required,
               properties: %{a: %{type: :integer}, b: %{type: :integer}},
               additionalProperties: false
             }
           } = AddNumbers.to_tool()

    assert Enum.sort(required) == [:a, :b]
  end

  test "exposes configured action modules as provider tools" do
    assert ToolAgent.tools() == [AddNumbers]
    assert ToolAgent.tool_names() == ["add_numbers"]

    assert %{
             tools: [AddNumbers],
             tool_names: ["add_numbers"]
           } = ToolAgent.__jidoka__()
  end

  test "inspection metadata exposes action modules and published operation names" do
    assert {:ok, definition} = Jidoka.inspect_agent(ToolAgent)

    assert definition.tools == [AddNumbers]
    assert definition.tool_names == ["add_numbers"]

    assert [
             %{
               name: "add_numbers",
               description: "Adds two integers together.",
               parameters_schema: %{type: :object}
             }
           ] = Enum.map(definition.tools, & &1.to_tool())
  end

  test "wraps Jido.Plugin with Jidoka.Plugin defaults" do
    assert MathPlugin.name() == "math_plugin"
    assert MathPlugin.state_key() == :math_plugin
    assert MathPlugin.actions() == [MultiplyNumbers]
  end

  test "exposes configured plugin modules and names" do
    assert PluginAgent.plugins() == [MathPlugin]
    assert PluginAgent.plugin_names() == ["math_plugin"]
  end

  test "merges plugin actions into the provider tool registry" do
    assert PluginAgent.tools() == [MultiplyNumbers]
    assert PluginAgent.tool_names() == ["multiply_numbers"]
  end

  test "plugin registries normalize and reject mismatched names" do
    assert {:ok, %{"math_plugin" => MathPlugin}} =
             Jidoka.Plugin.normalize_available_plugins([MathPlugin])

    assert {:ok, [MathPlugin]} =
             Jidoka.Plugin.resolve_plugin_names(["math_plugin"], %{"math_plugin" => MathPlugin})

    assert {:error, reason} =
             Jidoka.Plugin.normalize_available_plugins(%{"wrong_name" => MathPlugin})

    assert reason =~ "must match published plugin name"

    assert {:error, "unknown plugin \"missing_plugin\""} =
             Jidoka.Plugin.resolve_plugin_names(["missing_plugin"], %{"math_plugin" => MathPlugin})
  end

  test "rejects duplicate direct action operation names" do
    assert_raise Spark.Error.DslError, ~r/duplicate operation names.*add_numbers/s, fn ->
      compile_agent("""
      agent :duplicate_direct_action_agent do
        instructions "This should fail."
      end

      tools do
        action JidokaTest.AddNumbers
        action JidokaTest.AddNumbers
      end
      """)
    end
  end

  test "rejects invalid action output schemas" do
    assert_raise CompileError, ~r/must use a Zoi schema for output_schema\/0/, fn ->
      compile_source("""
      use Jidoka.Action,
        schema: Zoi.object(%{value: Zoi.string()}),
        output_schema: [value: [type: :string]]

      @impl true
      def run(params, _context), do: {:ok, params}
      """)
    end
  end

  test "action adapter normalizes callback failures without crashing registry validation" do
    module = unique_module("BadNameAction")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      def run(params, _context), do: {:ok, params}
      def name, do: raise("bad name")
      def schema, do: Zoi.object(%{})
      def output_schema, do: Zoi.object(%{})
      def to_tool, do: %{name: "bad_name", parameters_schema: %{}}
    end
    """)

    assert {:error, reason} = Jidoka.Action.Adapter.normalize_available_tools([module])
    assert reason =~ "failed while reading name/0"
    assert reason =~ "bad name"
  end

  # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
  test "action execution failures return errors without crashing the caller" do
    assert {:error, %Jido.Action.Error.ExecutionFailureError{message: "boom"}} =
             Jido.Exec.run(FailingAction, %{reason: "boom"}, %{}, max_retries: 0, log_level: :warning)
  end

  defp compile_agent(body) do
    module = unique_module("Agent")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use Jidoka.Agent

      #{body}
    end
    """)
  end

  defp compile_source(body) do
    module = unique_module("Action")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      #{body}
    end
    """)
  end

  defp unique_module(prefix) do
    Module.concat(JidokaTest.DynamicOperationSurface, "#{prefix}#{System.unique_integer([:positive])}")
  end
end
