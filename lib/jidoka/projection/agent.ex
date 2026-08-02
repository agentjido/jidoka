defmodule Jidoka.Projection.Agent do
  @moduledoc false

  alias Jidoka.Agent
  alias Jidoka.Handoff
  alias Jidoka.Portable
  alias Jidoka.Projection.Effect

  @spec project(Agent.State.t() | Agent.Message.t() | Handoff.t()) :: map()
  def project(%Agent.State{} = state) do
    %{
      messages: Enum.map(state.messages, &project/1),
      operation_results: Enum.map(state.operation_results, &Effect.project/1),
      metadata: Portable.project(state.metadata)
    }
  end

  def project(%Agent.Message{} = message), do: message |> Agent.Message.to_map() |> Portable.project()

  def project(%Handoff{} = handoff) do
    %{
      id: handoff.id,
      conversation_id: handoff.conversation_id,
      from_agent: Portable.project(handoff.from_agent),
      to_agent: inspect(handoff.to_agent),
      to_agent_id: handoff.to_agent_id,
      name: handoff.name,
      message: handoff.message,
      summary: handoff.summary,
      reason: handoff.reason,
      context: Portable.project(handoff.context),
      request_id: handoff.request_id,
      metadata: Portable.project(handoff.metadata)
    }
  end
end
