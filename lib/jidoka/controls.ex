defmodule Jidoka.Controls do
  @moduledoc false

  @type stage :: :input | :result | :operation
  @type control_ref ::
          module()
          | Jidoka.Control.Operation.t()
          | {module(), atom(), [term()]}
          | (term() -> Jidoka.Control.decision())
  @type stage_map :: %{
          input: [control_ref()],
          result: [control_ref()],
          operation: [control_ref()]
        }

  @spec default_stage_map() :: stage_map()
  def default_stage_map do
    Jidoka.Guardrails.default_stage_map()
    |> public_stage_map()
  end

  @spec normalize_request_controls(term()) :: {:ok, Jidoka.Guardrails.stage_map()} | {:error, term()}
  def normalize_request_controls(controls) do
    controls
    |> internal_stage_map()
    |> Jidoka.Guardrails.normalize_request_guardrails()
  end

  @spec attach_request_controls(map(), Jidoka.Guardrails.stage_map()) :: map()
  def attach_request_controls(context, controls) when is_map(context) and is_map(controls) do
    Jidoka.Guardrails.attach_request_guardrails(context, controls)
  end

  @spec public_stage_map(Jidoka.Guardrails.stage_map()) :: stage_map()
  def public_stage_map(%{} = controls) do
    %{
      input: Map.get(controls, :input, []),
      result: Map.get(controls, :output, []),
      operation: Map.get(controls, :tool, [])
    }
  end

  @spec internal_stage_map(term()) :: term()
  def internal_stage_map(nil), do: nil

  def internal_stage_map(controls) when is_list(controls) do
    controls
    |> Enum.map(fn
      {:result, refs} -> {:output, refs}
      {"result", refs} -> {"output", refs}
      {:operation, refs} -> {:tool, refs}
      {"operation", refs} -> {"tool", refs}
      other -> other
    end)
  end

  def internal_stage_map(%{} = controls) do
    controls
    |> maybe_move_stage(:result, :output)
    |> maybe_move_stage("result", "output")
    |> maybe_move_stage(:operation, :tool)
    |> maybe_move_stage("operation", "tool")
  end

  def internal_stage_map(other), do: other

  defp maybe_move_stage(controls, from, to) do
    case Map.pop(controls, from) do
      {nil, controls} -> controls
      {value, controls} -> Map.put(controls, to, value)
    end
  end
end
