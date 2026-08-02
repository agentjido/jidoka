defmodule JidokaExamples.SupportAgent.Scenario do
  @moduledoc false

  alias Jidoka.Runtime.JidoActions
  alias Jidoka.Schema
  alias JidokaExamples.SupportAgent.Actions.LookupOrder
  alias JidokaExamples.SupportAgent.Agent
  alias JidokaExamples.SupportAgent.ScriptedLLM

  def run(opts) do
    with {:ok, result} <- opts |> Keyword.drop([:credential_ref]) |> execute() do
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
      llm: mock_llm(order_id, observer),
      operation_context: operation_context
    )
  end

  def approve(snapshot, review, opts \\ []) do
    observer = Keyword.get(opts, :observer)
    order_id = Keyword.get(opts, :order_id, "A1001")

    Jidoka.approve(snapshot, review,
      reason: Keyword.get(opts, :reason, :operator_approved),
      llm: mock_llm(order_id, observer),
      operations: JidoActions.operations([LookupOrder]),
      operation_context: %{
        example_counter: Keyword.get(opts, :counter),
        example_observer: observer
      }
    )
  end

  defp mock_llm(order_id, observer) do
    ScriptedLLM.operation_round_trip(
      operation: "lookup_order",
      arguments: %{"order_id" => order_id},
      on_observation: &notify(observer, {:order_observation_seen, &1}),
      final: &final_content/1
    )
  end

  defp final_content(order) do
    if Schema.get_key(order, :status) == "not_found" do
      "Order #{Schema.get_key(order, :order_id)} was not found. " <>
        "#{Schema.get_key(order, :recommended_action)}"
    else
      "Order #{Schema.get_key(order, :order_id)} is " <>
        "#{format_status(Schema.get_key(order, :status))} with " <>
        "#{Schema.get_key(order, :carrier)}. ETA: #{Schema.get_key(order, :eta)}. " <>
        "#{Schema.get_key(order, :recommended_action)}"
    end
  end

  defp format_status(status), do: status |> to_string() |> String.replace("_", " ")

  defp notify(observer, message) when is_pid(observer), do: send(observer, message)
  defp notify(_observer, _message), do: :ok

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
