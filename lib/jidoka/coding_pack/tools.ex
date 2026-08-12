defmodule Jidoka.CodingPack.Tools do
  @moduledoc false

  alias Jidoka.CodingPack.{Read, Search, Workspace}

  @doc false
  @spec defaults(Workspace.t()) :: map()
  def defaults(%Workspace{} = workspace) do
    %{
      "coding.read" => Read.tool(workspace),
      "coding.search" => Search.tool(workspace)
    }
  end
end
