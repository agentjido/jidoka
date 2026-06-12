defmodule Jidoka.Tools.MixCheck do
  @moduledoc false

  use Jido.Action,
    name: "mix_check",
    description: "Run the allowlisted Jidoka project verification gate.",
    category: "workspace",
    tags: ["workspace", "mix", "verification"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        checks:
          Zoi.list(Zoi.string(), description: "Optional subset: format, compile, test, dialyzer")
          |> Zoi.optional(),
        timeout_ms:
          Zoi.integer(description: "Per-step timeout in milliseconds")
          |> Zoi.default(180_000)
      })

  alias Jidoka.Tools.{Context, ToolRuntime}
  alias Jidoka.VerificationCommand

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    ToolRuntime.run(context, __MODULE__, params, :write, fn ->
      workspace_path = Context.workspace_path(context)

      checks =
        Map.get(params, :checks) || Map.get(params, "checks") ||
          VerificationCommand.default_checks()

      timeout_ms = Map.get(params, :timeout_ms) || Map.get(params, "timeout_ms") || 180_000

      with {:ok, result} <-
             VerificationCommand.run(workspace_path,
               checks: checks,
               timeout_ms: timeout_ms,
               progress_fun: &report_step(context, &1, &2)
             ),
           :ok <- maybe_persist_report(context, result) do
        {:ok, Map.put(result, :workspace_path, workspace_path)}
      end
    end)
  end

  defp report_step(context, event, metadata) do
    Context.report_progress(context, event, "verification #{metadata.check}", metadata)
    :ok
  end

  defp maybe_persist_report(context, result) do
    case Context.attempt_workspace_path(context) do
      workspace_path when is_binary(workspace_path) ->
        report_path = Path.join(workspace_path, "verifier_report.md")
        File.mkdir_p!(Path.dirname(report_path))
        File.write!(report_path, render_report(result))

        Context.persist_artifact(context, %{
          id:
            "artifact-verifier-report-" <> Integer.to_string(System.unique_integer([:positive])),
          type: :verifier_report,
          status: :ready,
          location: report_path,
          metadata: %{status: result.status, checks: result.checks}
        })

      nil ->
        :ok
    end
  end

  defp render_report(result) do
    step_sections =
      Enum.map_join(result.steps, "\n\n", fn step ->
        """
        ## #{step.check}

        exit_status=#{step.exit_status}

        ```text
        #{step.output}
        ```
        """
      end)

    """
    # Verification Report

    status=#{result.status}
    checks=#{Enum.join(result.checks, ",")}

    #{step_sections}
    """
  end
end
