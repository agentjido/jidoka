defmodule Jidoka.Turn.State.OperationPlanner do
  @moduledoc false

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Id
  alias Jidoka.Turn

  @spec plan_turn(term(), Effect.LLMDecision.t(), String.t(), map()) ::
          {:ok, term()} | {:error, term()}
  def plan_turn(state, %Effect.LLMDecision{} = decision, name, arguments) do
    with {:ok, tool_call} <- one_tool_call(decision),
         {:ok, operation} <- fetch_operation(state, name),
         :ok <- Agent.Spec.validate_operation_policy(state.spec, operation) do
      {:ok, put_operation_effect(state, operation, decision, tool_call, name, arguments)}
    end
  end

  @spec plan_turns(term(), Effect.LLMDecision.t(), [Effect.OperationRequest.t()]) ::
          {:ok, term()} | {:error, term()}
  def plan_turns(state, %Effect.LLMDecision{} = decision, operations) do
    batch_size = length(operations)
    calls = tool_calls(decision)

    with :ok <- validate_tool_call_count(calls, batch_size),
         {:ok, effects} <- plan_batch_effects(state, operations, calls, batch_size) do
      {:ok, put_operation_effects(state, decision, operations, effects)}
    end
  end

  defp operation_for(%{spec: %{operations: operations}}, name) do
    Enum.find(operations, &(&1.name == name))
  end

  defp fetch_operation(state, name) do
    case operation_for(state, name) do
      nil -> {:error, {:unknown_operation, name}}
      operation -> {:ok, operation}
    end
  end

  defp plan_batch_effects(state, operations, calls, batch_size) do
    operations
    |> Enum.zip(calls)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{operation_request, tool_call}, index}, {:ok, effects} ->
      case plan_operation_effect(state, operation_request, tool_call, index, batch_size) do
        {:ok, effect} -> {:cont, {:ok, [effect | effects]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, effects} -> {:ok, Enum.reverse(effects)}
      error -> error
    end)
  end

  defp put_operation_effect(state, operation, decision, tool_call, name, arguments) do
    operation_request =
      Effect.OperationRequest.new!(
        name: name,
        arguments: arguments,
        request_id: state.request.request_id,
        loop_index: state.loop_index,
        provider_call_id: tool_call.provider_call_id,
        provider_metadata: tool_call.provider_metadata,
        tool_call: tool_call
      )

    effect = operation_effect(state, operation, operation_request, 0, 1)

    put_operation_effects(state, decision, [operation_request], [effect])
  end

  defp put_operation_effects(state, %Effect.LLMDecision{} = decision, operation_requests, effects) do
    agent_state = append_tool_call_message(state, decision)

    planned_state = %{
      state
      | llm_result: decision,
        agent_state: agent_state,
        operation_plan: List.first(operation_requests),
        pending_effects: effects
    }

    effects
    |> Enum.reduce(transition(planned_state), fn effect, transition ->
      transition_event(transition, :effect_planned,
        agent_id: state.spec.id,
        request_id: state.request.request_id,
        loop_index: state.loop_index,
        effect_id: effect.id,
        effect_kind: :operation,
        operation: effect_operation_name(effect),
        data: batch_metadata(effect)
      )
    end)
    |> Turn.Transition.commit()
  end

  defp plan_operation_effect(
         state,
         %Effect.OperationRequest{} = source_request,
         %Effect.ToolCall{} = tool_call,
         index,
         batch_size
       ) do
    case operation_for(state, source_request.name) do
      nil ->
        {:error, {:unknown_operation, source_request.name}}

      operation ->
        with :ok <- Agent.Spec.validate_operation_policy(state.spec, operation) do
          operation_request =
            Effect.OperationRequest.new!(
              name: source_request.name,
              arguments: source_request.arguments,
              request_id: state.request.request_id,
              loop_index: state.loop_index,
              provider_call_id: source_request.provider_call_id,
              provider_metadata: source_request.provider_metadata,
              tool_call: tool_call,
              metadata: Map.merge(source_request.metadata, %{batch_index: index, batch_size: batch_size})
            )

          {:ok, operation_effect(state, operation, operation_request, index, batch_size)}
        end
    end
  end

  defp operation_effect(state, operation, %Effect.OperationRequest{} = operation_request, index, batch_size) do
    name = operation_request.name
    arguments = operation_request.arguments
    payload = Effect.OperationRequest.to_payload(operation_request)

    {idempotency_key, metadata} =
      operation_effect_identity(state, name, arguments, index, batch_size)

    Effect.Intent.new(:operation, payload,
      idempotency: operation.idempotency,
      idempotency_key: idempotency_key,
      metadata: metadata
    )
  end

  defp operation_effect_identity(state, name, arguments, _index, 1) do
    idempotency_key =
      stable_key([
        state.spec.id,
        state.request.request_id,
        :operation,
        state.loop_index,
        name,
        arguments
      ])

    {idempotency_key, %{}}
  end

  defp operation_effect_identity(state, name, arguments, index, batch_size) do
    idempotency_key =
      stable_key([
        state.spec.id,
        state.request.request_id,
        :operation,
        state.loop_index,
        index,
        batch_size,
        name,
        arguments
      ])

    {idempotency_key, %{batch_index: index, batch_size: batch_size}}
  end

  defp effect_operation_name(%Effect.Intent{payload: payload}) do
    Map.get(payload, :name) || Map.get(payload, "name")
  end

  defp batch_metadata(%Effect.Intent{metadata: metadata}) when map_size(metadata) == 0, do: %{}
  defp batch_metadata(%Effect.Intent{metadata: metadata}), do: metadata

  defp transition(state), do: Turn.Transition.new!(state)

  defp transition_event(%Turn.Transition{} = transition, event, attrs) do
    Turn.Transition.event(transition, event, attrs)
  end

  defp stable_key(parts) do
    :crypto.hash(:sha256, :erlang.term_to_binary(parts))
    |> Base.url_encode64(padding: false)
  end

  defp tool_calls(%Effect.LLMDecision{
         interaction: %Effect.ModelInteraction{tool_call_groups: groups}
       }),
       do: Enum.flat_map(groups, & &1.calls)

  defp tool_calls(%Effect.LLMDecision{}), do: []

  defp one_tool_call(decision) do
    case tool_calls(decision) do
      [call] -> {:ok, call}
      calls -> {:error, {:tool_call_count_mismatch, 1, length(calls)}}
    end
  end

  defp validate_tool_call_count(calls, expected) do
    if length(calls) == expected,
      do: :ok,
      else: {:error, {:tool_call_count_mismatch, expected, length(calls)}}
  end

  defp append_tool_call_message(state, %Effect.LLMDecision{
         interaction: %Effect.ModelInteraction{} = interaction
       }) do
    message =
      Agent.Message.assistant_tool_calls(interaction,
        id: Id.stable("msg", [state.request.request_id, :assistant_tool_calls, interaction.interaction_id]),
        request_id: state.request.request_id,
        metadata: %{"loop_index" => state.loop_index}
      )

    Agent.Transcript.append(state.agent_state, message)
  end
end
