defmodule Jidoka.CodingPack.Tools do
  @moduledoc false

  alias Jidoka.CodingPack.{Edit, MutationPort, Read, Search, Workspace, Write}

  @doc false
  @spec defaults(Workspace.t(), keyword()) :: map()
  def defaults(%Workspace{} = workspace, opts \\ []) do
    defaults = %{
      "coding.read" => Read.tool(workspace),
      "coding.search" => Search.tool(workspace)
    }

    case Keyword.get(opts, :mutation) do
      %MutationPort{} = port ->
        Map.merge(defaults, %{
          "coding.edit" => Edit.tool(workspace, port),
          "coding.write" => Write.tool(workspace, port)
        })

      _value ->
        defaults
    end
  end
end
