defmodule Jidoka.Agent.ToolSources.Handoff do
  @moduledoc false

  alias Jidoka.Agent.Dsl.Handoff
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.Handoff, as: HandoffSource

  @spec source!(term()) :: HandoffSource.t()
  def source!(%Handoff{} = handoff) do
    HandoffSource.new!(
      agent: handoff.agent,
      as: handoff.as,
      description: handoff.description,
      target: handoff.target || :auto,
      forward_context: handoff.forward_context || :public,
      metadata: handoff.metadata || %{}
    )
  end

  @spec operations!(term()) :: [Jidoka.Agent.Spec.Operation.t()]
  def operations!(%Handoff{} = handoff) do
    handoff
    |> source!()
    |> Source.operations()
    |> case do
      {:ok, operations} -> operations
      {:error, reason} -> raise ArgumentError, "invalid handoff source: #{inspect(reason)}"
    end
  end

  @spec metadata!(term()) :: [map()]
  def metadata!(%Handoff{} = handoff) do
    source = source!(handoff)

    [
      %{
        "source" => "handoff",
        "name" => source.name,
        "agent" => inspect(source.agent),
        "target" => inspect(source.target),
        "forward_context" => inspect(source.forward_context)
      }
    ]
  end
end
