defmodule Jidoka.Agent.Verifiers.VerifyGuardrails do
  @moduledoc false

  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    (Spark.Dsl.Verifier.get_entities(dsl_state, [:lifecycle]) ++
       Spark.Dsl.Verifier.get_entities(dsl_state, [:controls]))
    |> Enum.filter(&guardrail_entity?/1)
    |> Enum.reduce_while({:ok, default_seen()}, fn
      control_ref, {:ok, seen} ->
        stage = stage_for(control_ref)
        ref = control_ref(control_ref)

        cond do
          duplicate_ref?(seen, stage, ref) ->
            {:halt, {:error, duplicate_guardrail_error(dsl_state, control_ref, stage)}}

          true ->
            case Jidoka.Guardrails.validate_dsl_guardrail_ref(stage, ref) do
              :ok ->
                {:cont, {:ok, put_seen(seen, stage, ref)}}

              {:error, message} ->
                {:halt, {:error, guardrail_error(dsl_state, control_ref, message)}}
            end
        end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp stage_for(%Jidoka.Agent.Dsl.InputControl{}), do: :input
  defp stage_for(%Jidoka.Agent.Dsl.ResultControl{}), do: :output
  defp stage_for(%Jidoka.Agent.Dsl.OperationControl{}), do: :tool

  defp guardrail_entity?(%Jidoka.Agent.Dsl.InputControl{}), do: true
  defp guardrail_entity?(%Jidoka.Agent.Dsl.ResultControl{}), do: true
  defp guardrail_entity?(%Jidoka.Agent.Dsl.OperationControl{}), do: true
  defp guardrail_entity?(_other), do: false

  defp control_ref(%{control: control}), do: control

  defp guardrail_error(dsl_state, guardrail_ref, message) do
    Spark.Error.DslError.exception(
      message: message,
      path: [:controls, stage_for(guardrail_ref)],
      module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module),
      location: Spark.Dsl.Entity.anno(guardrail_ref)
    )
  end

  defp duplicate_guardrail_error(dsl_state, guardrail_ref, stage) do
    Spark.Error.DslError.exception(
      message: "control #{inspect(control_ref(guardrail_ref))} is defined more than once for #{stage}",
      path: [:controls, stage],
      module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module),
      location: Spark.Dsl.Entity.anno(guardrail_ref)
    )
  end

  defp default_seen, do: %{input: MapSet.new(), output: MapSet.new(), tool: MapSet.new()}
  defp duplicate_ref?(seen, stage, ref), do: MapSet.member?(Map.fetch!(seen, stage), ref)
  defp put_seen(seen, stage, ref), do: Map.update!(seen, stage, &MapSet.put(&1, ref))
end
