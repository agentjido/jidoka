defmodule Jidoka.CodingPack.Tools do
  @moduledoc false

  alias Jidoka.CodingPack.{Edit, MutationPort, Read, Search, Shell, ShellPort, Workspace, Write}

  @doc false
  @spec defaults(Workspace.t(), keyword()) :: map()
  def defaults(%Workspace{} = workspace, opts \\ []) do
    defaults = %{
      "coding.read" => Read.tool(workspace),
      "coding.search" => Search.tool(workspace)
    }

    defaults
    |> add_mutations(workspace, Keyword.get(opts, :mutation))
    |> add_shell(workspace, Keyword.get(opts, :shell))
  end

  defp add_mutations(defaults, workspace, %MutationPort{} = port),
    do:
      Map.merge(defaults, %{
        "coding.edit" => Edit.tool(workspace, port),
        "coding.write" => Write.tool(workspace, port)
      })

  defp add_mutations(defaults, _workspace, _port), do: defaults

  defp add_shell(defaults, workspace, %ShellPort{} = port),
    do: Map.put(defaults, "coding.shell", Shell.tool(workspace, port))

  defp add_shell(defaults, _workspace, _port), do: defaults
end
