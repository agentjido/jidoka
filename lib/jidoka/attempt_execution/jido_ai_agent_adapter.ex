defmodule Jidoka.AttemptExecution.JidoAIAgentAdapter do
  @moduledoc """
  Prompt execution adapter backed by `Jido.AI.Agent`.
  """

  @behaviour Jidoka.AttemptExecution

  alias Jidoka.AI.CodingAgent
  alias Jidoka.AI.Runtime
  alias Jidoka.AttemptExecution
  alias Jidoka.AttemptExecution.{AttemptOutput, AttemptSpec}

  @impl true
  def execute(%AttemptSpec{} = spec) do
    try do
      with {:ok, runtime} <- Runtime.ensure_ready(spec_options(spec)),
           :ok <-
             AttemptExecution.report_progress(
               spec,
               :runtime_ready,
               "configured Jido AI runtime",
               %{model: runtime.model, timeout_ms: runtime.timeout_ms}
             ),
           {:ok, agent_pid} <- start_agent(spec, runtime),
           {:ok, output} <- run_prompt(spec, runtime, agent_pid) do
        {:ok, output}
      else
        {:error, reason} ->
          {:ok,
           %AttemptOutput{
             status: :terminal_failed,
             metadata: %{adapter: :jido_ai_agent},
             error: reason
           }}
      end
    rescue
      error ->
        {:ok,
         %AttemptOutput{
           status: :terminal_failed,
           metadata: %{adapter: :jido_ai_agent},
           error: Exception.message(error)
         }}
    end
  end

  defp start_agent(spec, runtime) do
    AttemptExecution.report_progress(
      spec,
      :agent_start,
      "starting Jido.AI coding agent",
      %{model: runtime.model}
    )

    case Jido.AgentServer.start_link(agent: CodingAgent) do
      {:ok, agent_pid} ->
        {:ok, agent_pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_prompt(spec, runtime, agent_pid) do
    try do
      with {:ok, request} <- dispatch_prompt(spec, runtime, agent_pid),
           {:ok, result} <- await_result(spec, runtime, request),
           {:ok, artifact, response_text} <- persist_prompt_report(spec, runtime, result) do
        {:ok,
         %AttemptOutput{
           status: :succeeded,
           metadata: %{
             adapter: :jido_ai_agent,
             model: runtime.model,
             response_text: response_text
           },
           artifacts: [artifact]
         }}
      end
    after
      stop_agent(agent_pid)
    end
  end

  defp dispatch_prompt(spec, runtime, agent_pid) do
    AttemptExecution.report_progress(
      spec,
      :prompt_dispatch,
      "sending prompt to Jido.AI.Agent",
      %{prompt_length: byte_size(spec.task), model: runtime.model}
    )

    CodingAgent.ask(agent_pid, spec.task,
      timeout: runtime.timeout_ms,
      stream_timeout_ms: runtime.timeout_ms,
      tool_context: tool_context(spec)
    )
  end

  defp await_result(spec, runtime, request) do
    AttemptExecution.report_progress(
      spec,
      :await_result,
      "waiting for agent completion",
      %{request_id: request.id, timeout_ms: runtime.timeout_ms}
    )

    with {:ok, result} <- CodingAgent.await(request, timeout: runtime.timeout_ms) do
      AttemptExecution.report_progress(
        spec,
        :response_ready,
        "received agent response",
        %{request_id: request.id}
      )

      {:ok, result}
    end
  end

  defp persist_prompt_report(spec, runtime, result) do
    response_text = Jido.AI.Request.compat_text(result)
    report_path = prompt_report_path(spec)

    File.mkdir_p!(Path.dirname(report_path))

    File.write!(
      report_path,
      """
      # Prompt

      #{spec.task}

      # Response

      #{response_text}
      """
    )

    AttemptExecution.report_progress(
      spec,
      :prompt_report_written,
      "persisted prompt report",
      %{location: report_path, model: runtime.model}
    )

    {:ok,
     %{
       id: artifact_id(spec),
       type: :prompt_report,
       status: :ready,
       location: report_path,
       metadata: %{model: runtime.model}
     }, response_text}
  end

  defp spec_options(%AttemptSpec{metadata: metadata}) when is_map(metadata) do
    [
      model: Map.get(metadata, :model) || Map.get(metadata, "model"),
      timeout_ms: Map.get(metadata, :timeout_ms) || Map.get(metadata, "timeout_ms")
    ]
  end

  defp spec_options(_spec), do: []

  defp tool_context(%AttemptSpec{} = spec) do
    metadata = spec.metadata

    %{
      jidoka_attempt_spec: spec,
      workspace_path:
        Map.get(metadata, :workspace_path) ||
          Map.get(metadata, "workspace_path") ||
          Map.get(metadata, :requested_cwd) ||
          Map.get(metadata, "requested_cwd") ||
          lease_source_workspace_path(spec) ||
          spec.environment_lease.workspace_path,
      permission_mode:
        Map.get(metadata, :permission_mode) ||
          Map.get(metadata, "permission_mode") ||
          System.get_env("JIDOKA_PERMISSION_MODE") ||
          :read_only
    }
  end

  defp lease_source_workspace_path(%AttemptSpec{environment_lease: %{metadata: metadata}})
       when is_map(metadata) do
    Map.get(metadata, :source_workspace_path) || Map.get(metadata, "source_workspace_path")
  end

  defp prompt_report_path(%AttemptSpec{} = spec) do
    Path.join(spec.environment_lease.workspace_path, "prompt_report.md")
  end

  defp artifact_id(%AttemptSpec{} = spec) do
    "artifact-prompt-report-" <> spec.attempt_id
  end

  defp stop_agent(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end
end
