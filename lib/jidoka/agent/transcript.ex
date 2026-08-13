defmodule Jidoka.Agent.Transcript do
  @moduledoc """
  Pure ordered transcript operations for durable agent state.

  Jidoka-generated messages have stable identifiers. Appending the same
  semantic message again is therefore a no-op, which makes snapshot replay and
  repeated phase entry safe.
  """

  alias Jidoka.Agent

  @doc "Appends one message unless its stable identifier is already present."
  @spec append(Agent.State.t(), Agent.Message.t()) :: Agent.State.t()
  def append(%Agent.State{} = state, %Agent.Message{id: nil} = message) do
    %Agent.State{state | messages: state.messages ++ [message]}
  end

  def append(%Agent.State{} = state, %Agent.Message{id: id} = message) do
    if Enum.any?(state.messages, &(&1.id == id)) do
      state
    else
      %Agent.State{state | messages: state.messages ++ [message]}
    end
  end

  @doc "Returns true when all non-null message identifiers are unique."
  @spec valid?(Agent.State.t()) :: boolean()
  def valid?(%Agent.State{} = state) do
    ids = state.messages |> Enum.map(& &1.id) |> Enum.reject(&is_nil/1)
    length(ids) == MapSet.size(MapSet.new(ids))
  end
end
