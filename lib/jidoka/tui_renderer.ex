defmodule Jidoka.TuiRenderer do
  @moduledoc """
  Stateless rendering helpers for shell output and render models.
  """

  alias Jidoka.TuiServer.State

  @artifact_type_labels %{
    diff: "diff",
    command_log: "log",
    verifier_report: "verifier report",
    prompt_report: "prompt report"
  }

  @event_fallback [
    "no runtime events yet",
    "waiting for snapshots or event stream"
  ]

  @focused_progress_fallback [
    "no attempt progress yet",
    "waiting for attempt progress event"
  ]

  @control_commands [
    :interrupt,
    :steer,
    :approve,
    :reject,
    :retry,
    :cancel,
    :focus_run,
    :reconnect
  ]

  @prompt "jidoka> "

  def render_model(%State{} = state) do
    status_lines = status_lines(state)
    focused_run_lines = focused_run_lines(state)
    artifact_lines = artifact_lines(state)
    event_lines = event_lines(state)
    input_lines = input_lines(state)

    %{
      status: %{
        heading: "status",
        lines: status_lines
      },
      focused_run: %{
        heading: "focused run",
        lines: focused_run_lines
      },
      artifacts: %{
        heading: "artifacts",
        lines: artifact_lines
      },
      events: %{
        heading: "event stream",
        lines: event_lines
      },
      input: %{
        heading: "operator input",
        lines: input_lines
      }
    }
  end

  def render(%State{} = state) do
    model = render_model(state)

    [
      render_region("status", model.status.lines),
      render_region("focused run", model.focused_run.lines),
      render_region("artifacts", model.artifacts.lines),
      render_region("event stream", model.events.lines),
      render_region("operator input", model.input.lines)
    ]
    |> Enum.join("\n")
  end

  defp render_region(name, lines) do
    heading = "[#{name}]"
    body = lines |> Enum.join("\n")
    heading <> "\n" <> body
  end

  defp status_lines(state) do
    connection_label = format_connection(state)

    [
      "summary=session=#{format_status_value(state.session_status)} run=#{format_status_value(state.active_run_status)} attempt=#{format_status_value(state.active_attempt_status)} lease=#{state.active_lease_id || "<none>"}",
      "connection=#{connection_label}",
      "session_id=#{state.session_ref || "<none>"}",
      "session_status=#{inspect(state.session_status)}",
      "active_run_id=#{state.active_run_id || "<none>"}",
      "available_runs=#{format_run_list(state.available_runs)}",
      "active_run_status=#{inspect(state.active_run_status)}",
      "active_attempt_id=#{state.active_attempt_id || "<none>"}",
      "active_attempt_status=#{inspect(state.active_attempt_status)}",
      "environment_lease=#{state.active_lease_id || "<none>"}",
      "environment_lease_workspace=#{state.active_lease_workspace_path || "<none>"}",
      "recoverable_reason=#{inspect(state.recoverable_reason)}",
      "commands=#{command_controls_line(state.command_controls)}",
      "command_error=#{inspect(state.last_error)}"
    ]
  end

  defp event_lines(state) do
    case state.activity_lines do
      [] ->
        @event_fallback

      lines ->
        lines
    end
  end

  defp focused_run_lines(state) do
    [
      "run_id=#{state.active_run_id || "<none>"}",
      "run_status=#{inspect(state.active_run_status)}",
      "run_task=#{state.active_run_task || "<none>"}",
      "run_attempt_count=#{state.active_run_attempt_count}",
      "attempt_id=#{state.active_attempt_id || "<none>"}",
      "attempt_number=#{state.active_attempt_number || "<none>"}",
      "attempt_status=#{inspect(state.active_attempt_status)}",
      "recent_progress:",
      "",
      maybe_progress_lines(state.focused_progress_lines),
      maybe_verification_lines(state.active_verification_result)
    ]
    |> List.flatten()
  end

  defp artifact_lines(state) do
    [
      artifact_section(:diff, state),
      artifact_section(:command_log, state),
      artifact_section(:verifier_report, state),
      artifact_section(:prompt_report, state)
    ]
    |> List.flatten()
  end

  defp artifact_section(type, state) do
    artifacts = Map.get(state.focused_artifacts || %{}, type, [])
    label = Map.get(@artifact_type_labels, type, Atom.to_string(type))

    [label <> ":", artifact_lines_for_type(artifacts)]
  end

  defp artifact_lines_for_type([]), do: ["  <none>"]
  defp artifact_lines_for_type(artifacts), do: Enum.map(artifacts, &artifact_summary_line/1)

  defp artifact_summary_line(artifact) do
    status = inspect(artifact.status)
    "  id=#{artifact.id || "<none>"} status=#{status} location=#{artifact.location || "<none>"}"
  end

  defp maybe_verification_lines(nil), do: ["verifier_status=<none>"]

  defp maybe_verification_lines(result) do
    [
      "verifier_status=#{inspect(result.status)}",
      "verifier_summary=#{inspect(result.outcome_summary || %{})}"
    ]
  end

  defp format_status_value(nil), do: "<none>"
  defp format_status_value(value) when is_atom(value), do: to_string(value)
  defp format_status_value(value), do: inspect(value)

  defp format_run_list(nil), do: "<none>"
  defp format_run_list([]), do: "<none>"
  defp format_run_list(runs), do: Enum.join(runs, ",")

  defp input_lines(state) do
    ["prompt=#{@prompt}", "buffer=#{state.input_buffer || ""}"]
  end

  defp maybe_progress_lines([]), do: @focused_progress_fallback
  defp maybe_progress_lines(lines), do: Enum.map(lines, &"  #{&1}")

  defp format_connection(%{mode: :attached}), do: "attached"
  defp format_connection(%{mode: :recoverable}), do: "recoverable"
  defp format_connection(_), do: "unknown"

  defp command_controls_line(nil), do: "controls=<none>"

  defp command_controls_line(controls) do
    @control_commands
    |> Enum.map(fn command ->
      "#{command}=#{Map.get(controls, command, :illegal)}"
    end)
    |> Enum.join(" ")
  end
end
