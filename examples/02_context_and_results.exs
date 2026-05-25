Mix.Task.run("app.start")

defmodule JidokaExamples.ContextAndResults.TicketClassifier do
  use Jidoka.Agent

  @result_schema Zoi.object(%{
                   category: Zoi.enum([:billing, :technical, :account]),
                   confidence: Zoi.float(),
                   summary: Zoi.string()
                 })

  agent :example_ticket_classifier do
    model :fast
    instructions "Classify the ticket and return the configured result object."

    context(
      Zoi.object(%{
        account_id: Zoi.string() |> Zoi.default("acct_demo"),
        actor_id: Zoi.string() |> Zoi.default("system")
      })
    )

    result @result_schema do
      repair 1
      on_validation_error :repair
    end
  end
end

alias JidokaExamples.ContextAndResults.TicketClassifier

session =
  TicketClassifier
  |> Jidoka.session("ticket-123",
    context: %{account_id: "acct_123", actor_id: "user_123"}
  )

{:ok, parsed_result} =
  TicketClassifier.result()
  |> Jidoka.Output.parse(~s({"category":"billing","confidence":0.94,"summary":"Invoice question"}))

IO.inspect(
  %{
    context: Jidoka.Session.chat_opts(session)[:context],
    result_schema: Jidoka.Output.json_schema(TicketClassifier.result()),
    parsed_result: parsed_result
  },
  label: "context_and_results"
)
