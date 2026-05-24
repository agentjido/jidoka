defmodule Jidoka.Guardrails.Config do
  @moduledoc false

  @request_guardrails_key :__jidoka_guardrails__
  @tool_guardrail_callback_key :__tool_guardrail_callback__
  @stages [:input, :output, :tool]

  @spec stages() :: [:input | :output | :tool]
  def stages, do: @stages

  @spec default_stage_map() :: Jidoka.Guardrails.stage_map()
  def default_stage_map do
    Jidoka.StageRefs.default_stage_map(@stages)
  end

  @spec normalize_dsl_guardrails(Jidoka.Guardrails.stage_map()) ::
          {:ok, Jidoka.Guardrails.stage_map()} | {:error, String.t()}
  def normalize_dsl_guardrails(guardrails) when is_map(guardrails) do
    Jidoka.StageRefs.normalize_dsl(guardrails, stage_ref_opts())
  end

  @spec normalize_request_guardrails(term()) :: {:ok, Jidoka.Guardrails.stage_map()} | {:error, term()}
  def normalize_request_guardrails(guardrails) do
    Jidoka.StageRefs.normalize_request(guardrails, stage_ref_opts())
  end

  @spec validate_dsl_guardrail_ref(Jidoka.Guardrails.stage(), term()) :: :ok | {:error, String.t()}
  def validate_dsl_guardrail_ref(stage, ref) when stage in @stages do
    Jidoka.StageRefs.validate_dsl_ref(stage, ref, stage_ref_opts())
  end

  @spec combine(Jidoka.Guardrails.stage_map(), Jidoka.Guardrails.stage_map()) :: Jidoka.Guardrails.stage_map()
  def combine(defaults, request_guardrails) do
    Jidoka.StageRefs.combine(@stages, defaults, request_guardrails)
  end

  @spec attach_request_guardrails(map(), Jidoka.Guardrails.stage_map()) :: map()
  def attach_request_guardrails(context, guardrails)
      when is_map(context) and is_map(guardrails) do
    if guardrails == default_stage_map() do
      context
    else
      Map.put(context, @request_guardrails_key, guardrails)
    end
  end

  @spec pop_request_guardrails(map()) :: {Jidoka.Guardrails.stage_map(), map()}
  def pop_request_guardrails(params) when is_map(params) do
    context = Map.get(params, :tool_context, %{}) || %{}
    {request_guardrails, context} = Map.pop(context, @request_guardrails_key, default_stage_map())
    {request_guardrails, Map.put(params, :tool_context, context)}
  end

  @spec tool_guardrail_callback_key() :: atom()
  def tool_guardrail_callback_key, do: @tool_guardrail_callback_key

  defp stage_ref_opts do
    [
      stages: @stages,
      spec_label: "controls",
      ref_label: "control",
      invalid_stage: :invalid_control_stage,
      invalid_spec: :invalid_control_spec,
      invalid_ref: :invalid_control,
      module_validator: &Jidoka.Control.validate_control_module/1,
      dsl_function_error: "DSL controls do not support anonymous functions; use a Jidoka.Control module or MFA instead",
      invalid_ref_message: fn other ->
        "control refs must be a Jidoka.Control module, MFA tuple, or runtime function, got: #{inspect(other)}"
      end
    ]
  end
end
