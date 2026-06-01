defmodule Jidoka.Turn.State do
  @moduledoc "Ephemeral data value passed through the V2 turn workflow."

  alias Jidoka.Schema
  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Turn

  @schema Zoi.struct(
            __MODULE__,
            %{
              spec: Zoi.lazy({Agent.Spec, :schema, []}),
              plan: Zoi.lazy({Turn.Plan, :schema, []}),
              request: Zoi.lazy({Turn.Request, :schema, []}),
              agent_state: Zoi.lazy({Agent.State, :schema, []}),
              memory: Zoi.lazy({Jidoka.Memory.RecallResult, :schema, []}) |> Zoi.nullish(),
              compactions: Zoi.array(Zoi.lazy({Jidoka.Memory.Compaction, :schema, []})) |> Zoi.default([]),
              prompt: Zoi.any() |> Zoi.nullish(),
              llm_result: Zoi.lazy({Effect.LLMDecision, :schema, []}) |> Zoi.nullish(),
              operation_plan: Zoi.lazy({Effect.OperationRequest, :schema, []}) |> Zoi.nullish(),
              pending_effects: Zoi.array(Zoi.lazy({Effect.Intent, :schema, []})) |> Zoi.default([]),
              pending_interrupt: Zoi.lazy({Jidoka.Review.Interrupt, :schema, []}) |> Zoi.nullish(),
              result: Zoi.string() |> Zoi.nullish(),
              result_value: Zoi.any() |> Zoi.nullish(),
              result_repair_count: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              status: Schema.atom_enum([:running, :waiting, :finished]) |> Zoi.default(:running),
              loop_index: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              started_at_ms: Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish(),
              journal: Zoi.lazy({Effect.Journal, :schema, []}),
              events: Zoi.array(Zoi.lazy({Jidoka.Event, :schema, []})) |> Zoi.default([]),
              diagnostics: Zoi.array(Zoi.any()) |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, prepare_attrs(attrs))

  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, prepare_attrs(attrs), "turn state")

  @spec from_snapshot(Jidoka.Runtime.AgentSnapshot.t()) :: {:ok, t()} | {:error, term()}
  def from_snapshot(%{turn_state: %__MODULE__{} = state}), do: new(state)

  defp prepare_attrs(attrs) do
    attrs
    |> Schema.normalize_attrs()
    |> normalize_pending_effects()
    |> Schema.put_default(:journal, Effect.Journal.new!())
  end

  @spec apply_effect_result(t(), Effect.Result.t()) :: {:ok, t()} | {:error, term()}
  def apply_effect_result(%__MODULE__{} = state, %Effect.Result{status: :ok} = result) do
    case current_pending_effect(state) do
      %Effect.Intent{kind: :llm} = effect ->
        with :ok <- ensure_result_for_effect(effect, result) do
          apply_llm_result(state, result.output)
        end

      %Effect.Intent{kind: :operation} = effect ->
        with :ok <- ensure_result_for_effect(effect, result) do
          apply_operation_result(state, effect, result.output)
        end

      nil ->
        {:error, {:missing_pending_effect, state}}
    end
  end

  def apply_effect_result(_state, %Effect.Result{status: :error, output: output}),
    do: {:error, output}

  def apply_effect_result(state, result), do: {:error, {:unexpected_effect_result, state, result}}

  @spec current_pending_effect(t()) :: Effect.Intent.t() | nil
  def current_pending_effect(%__MODULE__{pending_effects: [effect | _rest]}), do: effect
  def current_pending_effect(%__MODULE__{}), do: nil

  @spec pending_effect?(t()) :: boolean()
  def pending_effect?(%__MODULE__{} = state), do: not is_nil(current_pending_effect(state))

  @spec set_pending_effects(t(), [Effect.Intent.t()]) :: t()
  def set_pending_effects(%__MODULE__{} = state, effects) when is_list(effects) do
    %__MODULE__{state | pending_effects: effects}
  end

  @spec pop_pending_effect(t()) :: t()
  def pop_pending_effect(%__MODULE__{pending_effects: [_effect | rest]} = state) do
    %__MODULE__{state | pending_effects: rest}
  end

  def pop_pending_effect(%__MODULE__{} = state), do: state

  @spec put_pending_interrupt(t(), Jidoka.Review.Interrupt.t()) :: t()
  def put_pending_interrupt(%__MODULE__{} = state, %Jidoka.Review.Interrupt{} = interrupt) do
    %__MODULE__{state | pending_interrupt: interrupt, status: :waiting}
  end

  @spec clear_pending_interrupt(t()) :: t()
  def clear_pending_interrupt(%__MODULE__{} = state) do
    %__MODULE__{state | pending_interrupt: nil, status: :running}
  end

  defp normalize_pending_effects(%{} = attrs) do
    cond do
      Map.has_key?(attrs, :pending_effects) or Map.has_key?(attrs, "pending_effects") ->
        attrs

      Map.has_key?(attrs, :pending_effect) or Map.has_key?(attrs, "pending_effect") ->
        pending_effect = Map.get(attrs, :pending_effect, Map.get(attrs, "pending_effect"))

        attrs
        |> Map.delete(:pending_effect)
        |> Map.delete("pending_effect")
        |> Map.put(:pending_effects, pending_effects_from_legacy(pending_effect))

      true ->
        attrs
    end
  end

  defp normalize_pending_effects(attrs), do: attrs

  defp pending_effects_from_legacy(nil), do: []
  defp pending_effects_from_legacy(effect), do: [effect]

  defp apply_llm_result(%__MODULE__{} = state, output) when is_map(output) do
    state = pop_pending_effect(state)

    case Effect.LLMDecision.from_input(output) do
      {:ok, %Effect.LLMDecision{type: :final} = decision} ->
        apply_final_result(state, decision)

      {:ok, %Effect.LLMDecision{type: :operation, name: name, arguments: arguments} = decision} ->
        plan_operation_turn(state, decision, name, arguments)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_llm_result(_state, output), do: {:error, {:invalid_llm_output, output}}

  defp apply_operation_result(%__MODULE__{} = state, %Effect.Intent{} = effect, output) do
    with {:ok, observation} <- Effect.OperationResult.from_effect(effect, output) do
      state = pop_pending_effect(state)

      agent_state =
        state.agent_state
        |> append_message(Effect.OperationResult.to_message(observation))
        |> append_operation_result(observation)

      state =
        %__MODULE__{
          state
          | operation_plan: nil,
            agent_state: agent_state
        }
        |> transition()
        |> transition_event(:operation_observed,
          agent_id: state.spec.id,
          request_id: state.request.request_id,
          loop_index: state.loop_index,
          operation: observation.operation
        )
        |> Turn.Transition.commit()

      {:ok, state}
    end
  end

  defp ensure_result_for_effect(%Effect.Intent{id: id}, %Effect.Result{intent_id: id}), do: :ok

  defp ensure_result_for_effect(%Effect.Intent{} = effect, %Effect.Result{} = result) do
    {:error, {:effect_result_mismatch, effect, result}}
  end

  defp append_message(%Agent.State{messages: messages} = state, message) do
    %Agent.State{state | messages: messages ++ [message]}
  end

  defp append_operation_result(%Agent.State{operation_results: results} = state, result) do
    %Agent.State{state | operation_results: results ++ [result]}
  end

  defp apply_final_result(
         %__MODULE__{spec: %Agent.Spec{result: nil}} = state,
         %Effect.LLMDecision{content: content}
       ) do
    finish_turn(state, content, nil)
  end

  defp apply_final_result(
         %__MODULE__{spec: %Agent.Spec{result: %Agent.Spec.Result{} = result}} = state,
         %Effect.LLMDecision{} = decision
       ) do
    with {:ok, value} <- Agent.Spec.validate_result(state.spec, structured_final_value(decision)) do
      state =
        append_result_validated(state, value)

      finish_turn(state, decision.content, value)
    else
      {:error, {:invalid_result, reason}} ->
        maybe_repair_result(state, decision, result, reason)
    end
  end

  defp finish_turn(%__MODULE__{} = state, content, value) do
    message = Agent.Message.assistant(content)

    {:ok,
     %__MODULE__{
       state
       | pending_effects: [],
         result: content,
         result_value: value,
         status: :finished,
         agent_state: append_message(state.agent_state, message)
     }}
  end

  defp structured_final_value(%Effect.LLMDecision{result: nil, content: content}) do
    case Jason.decode(content) do
      {:ok, value} -> value
      {:error, _reason} -> content
    end
  end

  defp structured_final_value(%Effect.LLMDecision{result: result}), do: result

  defp maybe_repair_result(
         %__MODULE__{} = state,
         %Effect.LLMDecision{} = decision,
         %Agent.Spec.Result{} = result,
         reason
       ) do
    if state.result_repair_count < result.max_repairs do
      repair_count = state.result_repair_count + 1

      state =
        state
        |> append_result_repair_requested(decision, repair_count, reason)
        |> put_repair_message(repair_count, reason)

      {:ok,
       %__MODULE__{
         state
         | llm_result: decision,
           result_repair_count: repair_count,
           status: :running
       }}
    else
      {:error, {:invalid_result, reason, state.result_repair_count, result.max_repairs}}
    end
  end

  defp put_repair_message(%__MODULE__{} = state, repair_count, reason) do
    message =
      Agent.Message.user(
        "The previous final result did not match the declared result schema. " <>
          "Return a corrected final JSON object with a valid result field. " <>
          "Repair attempt #{repair_count}. Validation error: #{repair_reason(reason)}",
        metadata: %{
          "jidoka_result_repair" => true,
          "repair_count" => repair_count
        }
      )

    %__MODULE__{state | agent_state: append_message(state.agent_state, message)}
  end

  defp repair_reason(reason) when is_list(reason) do
    reason
    |> Enum.map(&repair_reason/1)
    |> Enum.join("; ")
  end

  defp repair_reason(%{path: path, message: message}) do
    path = Enum.map_join(List.wrap(path), ".", &to_string/1)

    case path do
      "" -> to_string(message)
      path -> "#{path}: #{message}"
    end
  end

  defp repair_reason(reason), do: inspect(reason)

  defp append_result_validated(%__MODULE__{} = state, value) do
    state
    |> transition()
    |> transition_event(:result_validated,
      agent_id: state.spec.id,
      request_id: state.request.request_id,
      loop_index: state.loop_index,
      data: %{result: value}
    )
    |> Turn.Transition.commit()
  end

  defp append_result_repair_requested(
         %__MODULE__{} = state,
         %Effect.LLMDecision{} = decision,
         repair_count,
         reason
       ) do
    state
    |> transition()
    |> transition_event(:result_repair_requested,
      agent_id: state.spec.id,
      request_id: state.request.request_id,
      loop_index: state.loop_index,
      data: %{
        repair_count: repair_count,
        content: decision.content
      },
      error: reason
    )
    |> Turn.Transition.commit()
  end

  defp plan_operation_turn(
         %__MODULE__{} = state,
         %Effect.LLMDecision{} = decision,
         name,
         arguments
       ) do
    case operation_for(state, name) do
      nil ->
        {:error, {:unknown_operation, name}}

      operation ->
        with :ok <- Agent.Spec.validate_operation_policy(state.spec, operation) do
          {:ok, put_operation_effect(state, operation, decision, name, arguments)}
        end
    end
  end

  defp operation_for(%__MODULE__{spec: %{operations: operations}}, name) do
    Enum.find(operations, &(&1.name == name))
  end

  defp put_operation_effect(%__MODULE__{} = state, operation, decision, name, arguments) do
    operation_request =
      Effect.OperationRequest.new!(
        name: name,
        arguments: arguments,
        request_id: state.request.request_id,
        loop_index: state.loop_index
      )

    payload = Effect.OperationRequest.to_payload(operation_request)

    effect =
      Effect.Intent.new(:operation, payload,
        idempotency: operation.idempotency,
        idempotency_key:
          stable_key([
            state.spec.id,
            state.request.request_id,
            :operation,
            state.loop_index,
            name,
            arguments
          ])
      )

    %__MODULE__{
      state
      | llm_result: decision,
        operation_plan: operation_request,
        pending_effects: [effect]
    }
    |> transition()
    |> transition_event(:effect_planned,
      agent_id: state.spec.id,
      request_id: state.request.request_id,
      loop_index: state.loop_index,
      effect_id: effect.id,
      effect_kind: :operation,
      operation: name
    )
    |> Turn.Transition.commit()
  end

  defp transition(%__MODULE__{} = state), do: Turn.Transition.new!(state)

  defp transition_event(%Turn.Transition{} = transition, event, attrs) do
    Turn.Transition.event(transition, event, attrs)
  end

  defp stable_key(parts) do
    :crypto.hash(:sha256, :erlang.term_to_binary(parts))
    |> Base.url_encode64(padding: false)
  end
end
