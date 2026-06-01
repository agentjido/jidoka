defmodule JidokaExample.AshAgent.Agent do
  @guide """
  This example shows Jidoka using an Ash resource as the tool source.

  The Jidoka DSL exposes `ash_resource`, AshJido generates the Jido actions,
  and the runtime passes the Ash domain through operation context. Ask it to
  create a customer, then ask it to list customers in the same session.

  The important package behavior is that Jidoka still runs a normal agent turn:
  the Ash action is just one operation capability in the same Runic loop.
  """
  @moduledoc @guide

  use Jidoka.Agent

  def guide, do: @guide

  agent :ash_agent do
    instructions """
    You are a concise CRM operations agent.

    Use create_customer when the user asks to add or create customers. The tool
    creates exactly one customer per call, so call it once for each distinct
    customer you are adding. Include name, company, tier, health_score, and
    notes when available. For multiple customers, call create_customer exactly
    once, wait for the tool result, then call create_customer again until the
    request is complete. Never write raw operation JSON in an assistant message.

    If the user asks for random, sample, or demo customers, generate realistic
    distinct customer names and call create_customer for each one. If no count
    is provided, create three sample customers. Do not ask for confirmation for
    random, sample, or demo data.

    Use list_customers with no arguments when the user asks what is already in
    the customer store. After list_customers returns, include each returned
    customer's name, company, tier, health_score, and notes in the answer.

    Customer names must be unique. If the user supplies the exact same name more
    than once, create at most one record for that name and explain that duplicate
    names are not allowed. If create_customer fails because a name already
    exists, tell the user that the customer already exists instead of implying
    another record was added.

    After tool calls, summarize only customer records returned by tools. Do not
    invent records in the final answer that were not returned by a tool.
    """

    generation %{params: %{temperature: 0.0, max_tokens: 800}}
  end

  controls do
    max_turns 8
    timeout 30_000
  end

  tools do
    ash_resource JidokaExample.AshAgent.Resources.Customer,
      actions: [:create_customer, :list_customers]
  end
end
