defmodule Jidoka.Agent.ToolSources.Subagent do
  @moduledoc false

  alias Jidoka.Agent.Dsl.Subagent
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.Subagent, as: SubagentSource

  @spec source!(term()) :: SubagentSource.t()
  def source!(%Subagent{} = subagent) do
    SubagentSource.new!(
      agent: subagent.agent,
      as: subagent.as,
      description: subagent.description,
      timeout: subagent.timeout || 30_000,
      forward_context: subagent.forward_context || :public,
      result: subagent.result || :structured,
      metadata: subagent.metadata || %{}
    )
  end

  @spec operations!(term()) :: [Jidoka.Agent.Spec.Operation.t()]
  def operations!(%Subagent{} = subagent) do
    subagent
    |> source!()
    |> Source.operations()
    |> case do
      {:ok, operations} -> operations
      {:error, reason} -> raise ArgumentError, "invalid subagent source: #{inspect(reason)}"
    end
  end

  @spec metadata!(term()) :: [map()]
  def metadata!(%Subagent{} = subagent) do
    source = source!(subagent)

    [
      %{
        "source" => "subagent",
        "name" => source.name,
        "agent" => inspect(source.agent),
        "timeout" => source.timeout,
        "forward_context" => inspect(source.forward_context),
        "result" => Atom.to_string(source.result)
      }
    ]
  end
end
