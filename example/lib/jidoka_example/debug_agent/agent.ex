defmodule JidokaExample.DebugAgent.Agent do
  @guide """
  Use this route to inspect how Jidoka sees an agent before and during a turn.

  Ask it to inspect or preflight one of the example agents. The route teaches
  the public debug APIs: Jidoka.inspect/1 shows compiled agent structure, and
  Jidoka.preflight/3 assembles the prompt and operation list without calling
  the LLM or tools.

  This is intentionally a developer-facing route. It should help you verify the
  data contracts that Jidoka will run before you debug model behavior.
  """
  @moduledoc @guide

  use Jidoka.Agent

  @debug_result_schema Zoi.object(%{
                         summary: Zoi.string(),
                         target: Zoi.string(),
                         checks:
                           Zoi.array(
                             Zoi.object(%{
                               name: Zoi.string(),
                               value: Zoi.string()
                             })
                           ),
                         operations:
                           Zoi.array(
                             Zoi.object(%{
                               name: Zoi.string(),
                               kind: Zoi.string()
                             })
                           )
                           |> Zoi.default([])
                       })

  def guide, do: @guide

  agent :debug_agent do
    instructions """
    You are a Jidoka debug agent for developers.

    Use inspect_agent when the user asks what an agent defines. Use
    preflight_agent when the user asks what prompt, context, operations, or
    timeline would be assembled before execution. You can call both tools when
    the user asks for a complete debug check.

    Valid targets are support, research, approval, ash, lead_quality, memory,
    knowledge, and kitchen_sink. Do not invent target names.

    After tool calls, summarize what the developer should notice. Return a
    structured result with summary, target, checks, and operations.
    """

    generation %{params: %{temperature: 0.0, max_tokens: 1_100}}

    result schema: @debug_result_schema, max_repairs: 2
  end

  controls do
    max_turns 5
    timeout 30_000
  end

  tools do
    action JidokaExample.DebugAgent.Actions.InspectAgent
    action JidokaExample.DebugAgent.Actions.PreflightAgent
  end
end
