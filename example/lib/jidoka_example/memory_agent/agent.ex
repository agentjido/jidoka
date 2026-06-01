defmodule JidokaExample.MemoryAgent.Agent do
  @guide """
  This example shows durable session memory through Jidoka's memory contract
  backed by `jido_memory`.

  First tell the agent a preference to remember. The agent should call
  remember_preference. Then ask a follow-up question in the same session; Jidoka
  recalls memory before prompt assembly and injects it into the model context.

  The point is not a custom app-level session store. The memory path is a
  Jidoka feature, with `jido_memory` providing the Jido ecosystem backend.
  """
  @moduledoc @guide

  use Jidoka.Agent

  def guide, do: @guide

  agent :memory_agent do
    instructions """
    You are a preference-aware assistant.

    When the user asks you to remember a preference, call remember_preference
    with the preference as a concise sentence. After the tool result, confirm
    what was stored.

    On later turns, use recalled memory when it is relevant. If recalled memory
    says the user prefers concise answers, keep the answer brief and mention
    that you are using the remembered preference when directly asked.
    """

    generation %{params: %{temperature: 0.0, max_tokens: 700}}

    memory %{scope: :session, max_entries: 5}
  end

  controls do
    max_turns 5
    timeout 30_000
  end

  tools do
    action JidokaExample.MemoryAgent.Actions.RememberPreference
  end
end
