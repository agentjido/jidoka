defmodule Jidoka.Tools.GitStatus do
  @moduledoc false

  use Jido.Action,
    name: "git_status",
    description: "Return git status for the current workspace. This is a read-only tool.",
    category: "workspace",
    tags: ["workspace", "git", "read-only"],
    vsn: "1.0.0",
    schema: []

  alias Jidoka.Tools.{Context, ToolRuntime}

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    ToolRuntime.run(context, __MODULE__, params, :read, fn ->
      workspace_path = Context.workspace_path(context)

      case System.find_executable("git") do
        nil ->
          {:error, %{type: :executable_not_found, executable: "git"}}

        git ->
          {output, exit_status} =
            System.cmd(git, ["status", "--short", "--branch"],
              cd: workspace_path,
              stderr_to_stdout: true
            )

          {:ok,
           %{
             workspace_path: workspace_path,
             exit_status: exit_status,
             output: String.trim_trailing(output)
           }}
      end
    end)
  end
end
