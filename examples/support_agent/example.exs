defmodule JidokaExamples.SupportAgent.Example do
  @moduledoc false

  @behaviour JidokaExamples.Example

  alias JidokaExamples.SupportAgent.Agent
  alias JidokaExamples.SupportAgent.LLMs.MockLLM

  @impl true
  def name, do: :support_agent

  @impl true
  def title, do: "Support Agent"

  @impl true
  def features do
    [
      :agent,
      :action,
      :tool_calling,
      :tool_observation,
      :operation_control,
      :human_review,
      :snapshot_resume
    ]
  end

  @impl true
  def summary do
    "Looks up an order through a Mock LLM and proves control, review, and resume behavior."
  end

  @impl true
  def run(opts \\ []) do
    case execute(opts) do
      {:ok, result} ->
        {:ok,
         %{
           example: name(),
           status: :ok,
           answer: result.content,
           operations:
             Enum.map(result.agent_state.operation_results, fn operation ->
               operation
               |> Jidoka.project()
               |> Map.take([:operation, :arguments, :output])
             end)
         }}

      {:hibernate, snapshot} ->
        {:ok,
         %{
           example: name(),
           status: :hibernate,
           pending_reviews: pending_reviews(snapshot)
         }}

      {:error, reason} ->
        {:error, reason}
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

    Agent.run_turn(request,
      llm: MockLLM.new(order_id, observer),
      operation_context: %{example_observer: observer}
    )
  end

  defp pending_reviews(snapshot) do
    case Jidoka.pending_reviews(snapshot) do
      {:ok, reviews} -> Enum.map(reviews, &Jidoka.project/1)
      {:error, reason} -> [%{error: Jidoka.format_error(reason)}]
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
