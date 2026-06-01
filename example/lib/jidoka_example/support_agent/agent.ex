defmodule JidokaExample.SupportAgent.Agent do
  @guide """
  Start here to see the smallest useful Jidoka agent running under Jido
  supervision: one agent module, one deterministic action, one visible tool
  call.

  Ask about order A1001. Watch the agent call lookup_order, answer from the
  returned order status, and publish the tool projection into the Activity tab.

  Notice that turn limits and timeouts live beside the agent definition in
  `controls`, so the runtime bounds are part of the agent spec.
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
