defmodule Jidoka.Runtime.JidoActionsTest.Support.EchoAction do
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
    {:ok, %{value: value, marker: Jidoka.Context.get(context, :marker)}}
  end
end

defmodule Jidoka.Runtime.JidoActionsTest do
  use ExUnit.Case, async: true

  alias Jidoka.Runtime.JidoActions, as: Actions
  alias Jidoka.Runtime.JidoActionsTest.Support.EchoAction
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
    ctx = Jidoka.Context.from_data!(marker: "unit")

    intent =
      Effect.Intent.new(:operation, %{name: "echo_value", arguments: %{"value" => "hello"}})

    assert {:ok, %{"value" => "hello", "marker" => "unit"}} =
             capability.(intent, Effect.Journal.new!(), ctx)
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
