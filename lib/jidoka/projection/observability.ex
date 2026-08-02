defmodule Jidoka.Projection.Observability do
  @moduledoc false

  alias Jidoka.Event
  alias Jidoka.Portable
  alias Jidoka.Projection.{AgentSpec, Turn}

  @spec project(
          Jidoka.Debug.RequestSummary.t()
          | Jidoka.Debug.ReplayDiagnostics.t()
          | Jidoka.Trace.Policy.t()
          | Jidoka.Eval.Case.t()
          | Jidoka.Eval.Run.t()
          | Event.t()
        ) :: map()
  def project(%Jidoka.Debug.RequestSummary{} = summary),
    do: summary |> Map.from_struct() |> Portable.project()

  def project(%Jidoka.Debug.ReplayDiagnostics{} = diagnostics),
    do: diagnostics |> Map.from_struct() |> Portable.project()

  def project(%Jidoka.Trace.Policy{} = policy) do
    %{
      enabled: policy.enabled,
      sample_rate: policy.sample_rate,
      redact_keys: policy.redact_keys,
      omit_keys: policy.omit_keys,
      metadata: Portable.project(policy.metadata)
    }
  end

  def project(%Jidoka.Eval.Case{} = eval_case) do
    %{
      id: eval_case.id,
      agent: project_agent(eval_case.agent),
      request: Turn.project(eval_case.request),
      assertions: Portable.project(eval_case.assertions),
      metadata: Portable.project(eval_case.metadata)
    }
  end

  def project(%Jidoka.Eval.Run{} = run) do
    %{
      case_id: run.case_id,
      status: run.status,
      result: project_result(run.result),
      error: Portable.project(run.error),
      assertions: Portable.project(run.assertions),
      observations: Portable.project(run.observations),
      metadata: Portable.project(run.metadata)
    }
  end

  def project(%Event{} = event), do: Event.to_map(event)

  defp project_agent(%Jidoka.Agent.Spec{} = spec), do: AgentSpec.project(spec)
  defp project_agent(value), do: Portable.project(value)
  defp project_result(nil), do: nil
  defp project_result(result), do: Turn.project(result)
end
