defmodule JidokaExample.SupportAgent.Agent do
  @guide """
  The Support Agent is the first rung in the example ladder: one supervised
  Jidoka agent, one deterministic action, one visible tool call.

  Try asking about order A1001. The agent should call lookup_order, answer from
  the returned order status, and show the tool projection in the Activity tab.

  This example also keeps basic operational controls close to the agent
  definition so new developers can see where turn limits and timeouts live.
  """
  @moduledoc @guide

  use Jidoka.Agent

  def guide, do: @guide

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

  controls do
    max_turns 4
    timeout 20_000
  end

  tools do
    action JidokaExample.SupportAgent.Actions.LookupOrder
  end
end
