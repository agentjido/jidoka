defmodule Jidoka.Effect.OperationGroupTest do
  use ExUnit.Case, async: true

  alias Jidoka.Effect
  alias Jidoka.Effect.OperationGroup

  test "keeps manifest order across out-of-order starts and completions" do
    intents = [intent("a"), intent("b"), intent("c")]
    assert {:ok, group} = OperationGroup.new(intents)

    assert {:ok, group} = OperationGroup.start(group, "c")
    assert {:ok, group} = OperationGroup.start(group, "a")
    assert group.started_intent_ids == ["a", "c"]
    assert group.status == :running

    assert {:ok, group} = OperationGroup.complete(group, "c")
    assert {:ok, group} = OperationGroup.complete(group, "a")
    assert group.completed_intent_ids == ["a", "c"]
    assert group.status == :running

    assert {:ok, group} = OperationGroup.start(group, "b")
    assert {:ok, group} = OperationGroup.complete(group, "b")
    assert group.started_intent_ids == ["a", "b", "c"]
    assert group.completed_intent_ids == ["a", "b", "c"]
    assert group.status == :completed
  end

  test "rejects completion before start and intents outside the manifest" do
    group = OperationGroup.new!([intent("a")])

    assert {:error, {:operation_group_intent_not_started, "a"}} =
             OperationGroup.complete(group, "a")

    assert {:error, {:operation_group_unknown_intent, "missing"}} =
             OperationGroup.start(group, "missing")
  end

  test "journal and projection retain one durable group manifest" do
    intents = [intent("a"), intent("b")]
    group = OperationGroup.new!(intents)
    {:ok, group} = OperationGroup.start(group, "a")

    journal =
      Effect.Journal.new!()
      |> Effect.Journal.put_operation_group(group)
      |> Effect.Journal.put_intent(hd(intents))

    assert Effect.Journal.operation_group(journal, group.id) == group

    assert %{operation_groups: [projected]} = Jidoka.project(journal)
    assert projected.intent_ids == ["a", "b"]
    assert projected.started_intent_ids == ["a"]
    assert projected.completed_intent_ids == []
    assert projected.status == :running

    assert {:ok, restored} =
             Effect.Journal.new(operation_groups: %{group.id => Map.from_struct(group)})

    assert Effect.Journal.operation_group(restored, group.id) == group
  end

  defp intent(id), do: Effect.Intent.new(:operation, %{name: id, arguments: %{}}, id: id)
end
