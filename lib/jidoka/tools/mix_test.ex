defmodule Jidoka.Tools.MixTest do
  @moduledoc false

  use Jido.Action,
    name: "mix_test",
    description: "Run an allowlisted mix test command in the workspace.",
    category: "workspace",
    tags: ["workspace", "mix", "test"],
    vsn: "1.0.0",
    schema: [
      target: [
        type: :string,
        required: false,
        doc: "Optional workspace-relative test file or file:line target."
      ],
      timeout_ms: [
        type: :integer,
        required: false,
        default: 120_000,
        doc: "Command timeout in milliseconds."
      ]
    ]

  alias Jidoka.Tools.{Command, Context, ToolRuntime, Workspace}

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    ToolRuntime.run(context, __MODULE__, params, :write, fn ->
      workspace_path = Context.workspace_path(context)
      target = Map.get(params, :target) || Map.get(params, "target")
      timeout_ms = Map.get(params, :timeout_ms) || Map.get(params, "timeout_ms") || 120_000

      with {:ok, args} <- test_args(workspace_path, target),
           {:ok, result} <- Command.run("mix", args, cd: workspace_path, timeout_ms: timeout_ms) do
        {:ok, Map.merge(result, %{workspace_path: workspace_path})}
      end
    end)
  end

  defp test_args(_workspace_path, nil), do: {:ok, ["test"]}
  defp test_args(_workspace_path, ""), do: {:ok, ["test"]}

  defp test_args(workspace_path, target) when is_binary(target) do
    {path, line_suffix} = split_line_suffix(target)

    with {:ok, file_path} <- Workspace.resolve_existing_path(workspace_path, path) do
      relative = Path.relative_to(file_path, workspace_path)
      {:ok, ["test", relative <> line_suffix]}
    end
  end

  defp split_line_suffix(target) do
    case Regex.run(~r/^(.+?)(:\d+)$/, target) do
      [_, path, line_suffix] -> {path, line_suffix}
      _ -> {target, ""}
    end
  end
end
