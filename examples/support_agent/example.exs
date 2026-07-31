defmodule JidokaExamples.SupportAgent.Example do
  @moduledoc false

  @behaviour JidokaExamples.Example

  alias Jidoka.Runtime.JidoActions
  alias JidokaExamples.SupportAgent.Actions.LookupOrder
  alias JidokaExamples.SupportAgent.Agent
  alias JidokaExamples.SupportAgent.LLMs.MockLLM

  @impl true
  def run(opts) do
    with {:ok, result} <- opts |> Keyword.drop([:credential_ref, :example]) |> execute() do
      {:ok,
       %{
         answer: result.content,
         operations:
           Enum.map(result.agent_state.operation_results, fn operation ->
             operation
             |> Jidoka.project()
             |> Map.take([:operation, :arguments, :output])
           end)
       }}
    end
  end

  def execute(opts \\ []) do
    observer = Keyword.get(opts, :observer)
    order_id = Keyword.get(opts, :order_id, "A1001")

    context =
      %{
        account_id: Keyword.get(opts, :account_id, "acct_123"),
        actor_id: Keyword.get(opts, :actor_id, "user_123")
      }
      |> maybe_put(:credential_ref, Keyword.get(opts, :credential_ref))

    request =
      Jidoka.Turn.Request.new!(
        input: "Check order #{order_id} and tell me what to do next.",
        context: context
      )

    operation_context = %{
      example_counter: Keyword.get(opts, :counter),
      example_observer: observer
    }

    Agent.run_turn(request,
      llm: MockLLM.new(order_id, observer),
      operation_context: operation_context
    )
  end

  def approve(snapshot, review, opts \\ []) do
    observer = Keyword.get(opts, :observer)
    order_id = Keyword.get(opts, :order_id, "A1001")

    Jidoka.approve(snapshot, review,
      reason: Keyword.get(opts, :reason, :operator_approved),
      llm: MockLLM.new(order_id, observer),
      operations: JidoActions.operations([LookupOrder]),
      operation_context: %{
        example_counter: Keyword.get(opts, :counter),
        example_observer: observer
      }
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
