defmodule JidokaExamples.SupportAgent.Scenario do
  @moduledoc false

  alias Jidoka.Snapshot
  alias Jidoka.Adapter.Jido.Actions
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
      operations: Actions.operations([LookupOrder]),
      operation_context: %{
        example_counter: Keyword.get(opts, :counter),
        example_observer: observer
      }
    )
  end

  def review_and_resume(opts \\ []) do
    observer = Keyword.get(opts, :observer, self())
    counter = Keyword.get_lazy(opts, :counter, &start_counter!/0)

    with {:hibernate, %Snapshot{} = snapshot} <-
           execute(
             observer: observer,
             counter: counter,
             credential_ref: Keyword.get(opts, :credential_ref, "credential:support-demo")
           ),
         {:ok, serialized} <- Snapshot.serialize(snapshot),
         {:ok, %Snapshot{} = restored} <- Snapshot.deserialize(serialized),
         {:ok, [review]} <- Jidoka.pending_reviews(restored),
         {:ok, result} <- approve(serialized, review, observer: observer, counter: counter) do
      {:ok,
       %{
         answer: result.content,
         operation_calls: Elixir.Agent.get(counter, & &1),
         review: review,
         schema_version: restored.schema_version,
         serialized_bytes: byte_size(serialized)
       }}
    end
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

  defp start_counter! do
    {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)
    counter
  end
end
