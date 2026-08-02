defmodule Jidoka.Adapter.Jido.ActionsTest.Support.EchoAction do
  use Jidoka.Action,
    name: "echo_value",
    description: "Echoes a value through Jido.Action.",
    schema:
      Zoi.object(%{
        value: Zoi.string()
      })

  @impl true
  def run(params, context) do
    value = Map.get(params, :value) || Map.get(params, "value")

    {:ok,
     %{
       value: value,
       marker: Map.get(context, :marker),
       access_marker: context[:marker],
       helper_marker: Jidoka.Context.get(context, :marker),
       runtime_marker: Jidoka.Context.get_runtime(context, :runtime_marker)
     }}
  end
end

defmodule Jidoka.Adapter.Jido.ActionsTest do
  use ExUnit.Case, async: true

  alias Jidoka.Adapter.Jido.Actions, as: Actions
  alias Jidoka.Adapter.Jido.ActionsTest.Support.EchoAction
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect

  test "converts Jido actions into operation specs" do
    assert %Operation{} = operation = Actions.operation_from_action!(EchoAction)

    assert operation.name == "echo_value"
    assert operation.description == "Echoes a value through Jido.Action."
    assert operation.metadata["runtime"] == "jido_action"
    assert operation.metadata["action"] == inspect(EchoAction)
    assert is_map(operation.metadata["parameters_schema"])

    assert [%Operation{name: "echo_value"}] = Actions.operations_from_actions([EchoAction])
  end

  test "executes Jido action tools and decodes JSON payloads" do
    capability = Actions.operations([EchoAction])
    ctx = Jidoka.Context.from_data!([marker: "unit"], runtime: %{runtime_marker: "trusted"})

    intent =
      Effect.Intent.new(:operation, %{name: "echo_value", arguments: %{"value" => "hello"}})

    assert {:ok,
            %{
              "value" => "hello",
              "marker" => "unit",
              "access_marker" => "unit",
              "helper_marker" => "unit",
              "runtime_marker" => "trusted"
            }} =
             capability.(intent, Effect.Journal.new!(), ctx)
  end

  test "normalizes invalid Jido action tool results" do
    context = Jidoka.Context.from_data!(%{})
    tool = %{function: fn _arguments, _context -> :invalid end}
    raw_tool = %{function: fn _arguments, _context -> {:ok, %{raw: true}} end}

    assert {:error, {:invalid_action_result, :invalid}} =
             Actions.invoke_tool(tool, %{}, context)

    assert {:ok, %{raw: true}} = Actions.invoke_tool(raw_tool, %{}, context)
    assert {:error, :invalid_action_tool} = Actions.invoke_tool(%{}, %{}, context)
  end

  test "reports missing Jido action tools" do
    capability = Actions.operations([EchoAction])
    intent = Effect.Intent.new(:operation, %{name: "missing", arguments: %{}})

    assert {:error, {:missing_jido_action, "missing"}} =
             capability.(intent, Effect.Journal.new!(), Jidoka.Context.from_data!(%{}))
  end

  test "rejects unsupported effect kinds" do
    capability = Actions.operations([EchoAction])
    intent = Effect.Intent.new(:llm, %{prompt: %{}})

    assert {:error, {:unsupported_effect_kind, :llm}} =
             capability.(intent, Effect.Journal.new!(), Jidoka.Context.from_data!(%{}))
  end
end
