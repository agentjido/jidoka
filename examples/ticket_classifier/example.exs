defmodule JidokaExamples.TicketClassifierExample do
  @behaviour JidokaExamples.Example

  alias JidokaExamples.ContextAndResults.TicketClassifier

  @impl true
  def name, do: :ticket_classifier

  @impl true
  def title, do: "Ticket Classifier"

  @impl true
  def features, do: [:context, :result, :structured_output, :repair]

  @impl true
  def summary, do: "Adds runtime context and a structured result contract with repair retries."

  @impl true
  def run(opts \\ []) do
    case JidokaExamples.mode(opts) do
      :live -> run_live(opts)
      :verify -> run_verify(opts)
    end
  end

  defp run_verify(_opts) do
    session =
      Jidoka.session(TicketClassifier, "ticket-123", context: %{account_id: "acct_123", actor_id: "user_123"})

    {:ok, parsed_result} =
      TicketClassifier.result()
      |> Jidoka.Output.parse(~s({"category":"billing","confidence":0.94,"summary":"Invoice question"}))

    {:ok,
     %{
       example: name(),
       mode: :verify,
       agent_id: TicketClassifier.id(),
       context: Jidoka.Session.chat_opts(session)[:context],
       result_schema: Jidoka.Output.json_schema(TicketClassifier.result()),
       parsed_result: parsed_result,
       repair_retries: TicketClassifier.result().retries
     }}
  end

  defp run_live(opts) do
    with {:ok, provider_env} <- JidokaExamples.require_live_provider(opts) do
      prompt =
        JidokaExamples.prompt(
          opts,
          "Classify this ticket: Customer says the invoice total doubled after plan renewal."
        )

      session =
        Jidoka.session(TicketClassifier, "ticket-live", context: %{account_id: "acct_live", actor_id: "user_live"})

      try do
        result = Jidoka.chat(session, prompt, timeout: 60_000)

        with {:ok, response} <- JidokaExamples.live_chat_summary(result) do
          {:ok,
           %{
             example: name(),
             mode: :live,
             provider_env: provider_env,
             response: response
           }}
        end
      after
        if pid = Jidoka.Session.whereis(session), do: Jidoka.stop_agent(pid)
      end
    end
  end
end
