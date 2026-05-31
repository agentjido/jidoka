defmodule JidokaExample.SupportAgent.Agent do
  @moduledoc false

  use Jidoka.Agent

  agent :support_agent do
    instructions """
    You are a concise customer support agent.

    When a customer asks about an order, call lookup_order exactly once before
    answering. Use the returned status, ETA, carrier, summary, and recommended
    action. Do not invent order details.

    If the order is not found, explain that clearly and ask for the correct
    order id.
    """

    generation %{params: %{temperature: 0.0, max_tokens: 700}}
  end

  tools do
    action JidokaExample.SupportAgent.Actions.LookupOrder
  end
end
