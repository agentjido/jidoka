defmodule JidokaExamples.ContextAndResults.TicketClassifier do
  use Jidoka.Agent

  @context_fields %{
    account_id: Zoi.string() |> Zoi.default("acct_demo"),
    actor_id: Zoi.string() |> Zoi.default("system")
  }

  @result_fields %{
    category: Zoi.enum([:billing, :technical, :account]),
    confidence: Zoi.float(),
    summary: Zoi.string()
  }

  agent :example_ticket_classifier do
    model :fast

    instructions """
    Classify support tickets.
    Return only the configured result object.
    """

    context Zoi.object(@context_fields)

    result Zoi.object(@result_fields) do
      repair 2
      on_validation_error :repair
    end
  end
end
