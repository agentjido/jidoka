defmodule Jidoka.UsageTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Runtime.LocalOperations
  alias Jidoka.Turn

  test "normalizes provider usage maps into canonical usage keys" do
    assert Jidoka.Usage.normalize(%{
             "input" => 10,
             "output" => 5,
             "reasoning_tokens" => 2,
             "total_cost" => 0.004,
             :cost => %{provider_specific: true}
           }) == %{
             input_tokens: 10,
             output_tokens: 5,
             total_tokens: 15,
             reasoning_tokens: 2,
             total_cost: 0.004
           }
  end

  test "turn results aggregate usage across LLM calls and keep per-effect metadata" do
    spec =
      Agent.Spec.new!(
        id: "usage_agent",
        instructions: "Use lookup when useful, then answer.",
        operations: [
          Operation.new!(
            name: "lookup",
            description: "Looks up a value.",
            idempotency: :idempotent
          )
        ],
        runtime_defaults: %{max_model_turns: 4}
      )

    llm = fn _intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "lookup",
             arguments: %{"id" => "A-1"},
             metadata: %{
               usage: %{"input_tokens" => 10, "output_tokens" => 5, "total_cost" => 0.001},
               model: "test:model",
               finish_reason: :tool_calls
             }
           }}

        1 ->
          {:ok,
           %{
             type: :final,
             content: "A-1 is ready.",
             metadata: %{
               usage: %{input: 20, output: 5, input_cost: 0.002, total_cost: 0.004},
               model: "test:model",
               finish_reason: :stop
             }
           }}
      end
    end

    operations =
      LocalOperations.operations(%{
        lookup: fn intent, _journal, _ctx ->
          {:ok, %{id: intent.payload.arguments["id"], status: "ready"}}
        end
      })

    assert {:ok, %Turn.Result{} = result} =
             Jidoka.turn(spec, "Check A-1", llm: llm, operations: operations)

    assert result.content == "A-1 is ready."
    assert result.usage.llm_calls == 2
    assert result.usage.input_tokens == 30
    assert result.usage.output_tokens == 10
    assert result.usage.total_tokens == 40
    assert_in_delta result.usage.total_cost, 0.005, 1.0e-9

    llm_results =
      result.journal.results
      |> Map.values()
      |> Enum.filter(&(&1.kind == :llm))

    assert Enum.count(llm_results) == 2
    assert Enum.all?(llm_results, &is_map(&1.metadata.usage))
    assert Enum.all?(llm_results, &(&1.metadata.model == "test:model"))
  end

  defp count_results(%Effect.Journal{results: results}, kind) do
    results
    |> Map.values()
    |> Enum.count(&(&1.kind == kind))
  end
end
