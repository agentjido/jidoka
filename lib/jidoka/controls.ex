defmodule Jidoka.Controls do
  @moduledoc """
  Public helpers for normalizing and attaching request-scoped controls.

  The public DSL uses the stage names `:input`, `:operation`, and `:result`.
  The runtime still delegates to the older internal guardrail machinery, so
  this module keeps the public vocabulary stable while translating to the
  internal stage names where needed.
  """

  @type stage :: :input | :result | :operation
  @type control_ref ::
          module()
          | struct()
          | {module(), atom(), [term()]}
          | (term() -> Jidoka.Control.decision())
  @type stage_map :: %{
          input: [control_ref()],
          result: [control_ref()],
          operation: [control_ref()]
        }
  @type runtime_stage_map :: %{
          input: [control_ref()],
          output: [control_ref()],
          tool: [control_ref()]
        }

  @spec default_stage_map() :: stage_map()
  @doc """
  Returns an empty public controls stage map.
  """
  def default_stage_map do
    Jidoka.Guardrails.default_stage_map()
    |> public_stage_map()
  end

  @spec normalize_request_controls(term()) :: {:ok, runtime_stage_map()} | {:error, term()}
  @doc """
  Normalizes request-scoped controls into the internal runtime stage map.
  """
  def normalize_request_controls(controls) do
    controls
    |> internal_stage_map()
    |> Jidoka.Guardrails.normalize_request_guardrails()
  end

  @spec attach_request_controls(map(), runtime_stage_map()) :: map()
  @doc """
  Stores normalized request-scoped controls in the runtime context.
  """
  def attach_request_controls(context, controls) when is_map(context) and is_map(controls) do
    Jidoka.Guardrails.attach_request_guardrails(context, controls)
  end

  @spec public_stage_map(runtime_stage_map()) :: stage_map()
  @doc """
  Converts the internal runtime stage map to public controls stage names.
  """
  def public_stage_map(%{} = controls) do
    %{
      input: Map.get(controls, :input, []),
      result: Map.get(controls, :output, []),
      operation: Map.get(controls, :tool, [])
    }
  end

  @spec internal_stage_map(term()) :: term()
  @doc """
  Converts public controls stage names to internal runtime stage names.
  """
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
