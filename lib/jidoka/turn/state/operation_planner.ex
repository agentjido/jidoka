defmodule Jidoka.Turn.State.OperationPlanner do
  @moduledoc false

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Turn

  @spec plan_turn(term(), Effect.LLMDecision.t(), String.t(), map()) ::
          {:ok, term()} | {:error, term()}
  def plan_turn(state, %Effect.LLMDecision{} = decision, name, arguments) do
    case operation_for(state, name) do
      nil ->
        {:error, {:unknown_operation, name}}

      operation ->
        with :ok <- Agent.Spec.validate_operation_policy(state.spec, operation) do
          {:ok, put_operation_effect(state, operation, decision, name, arguments)}
        end
    end
  end

  @spec plan_turns(term(), Effect.LLMDecision.t(), [Effect.OperationRequest.t()]) ::
          {:ok, term()} | {:error, term()}
  def plan_turns(state, %Effect.LLMDecision{} = decision, operations) do
    batch_size = length(operations)

    operations
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {operation_request, index}, {:ok, effects} ->
      case plan_operation_effect(state, operation_request.name, operation_request.arguments, index, batch_size) do
        {:ok, effect} -> {:cont, {:ok, [effect | effects]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, effects} ->
        effects = Enum.reverse(effects)
        {:ok, put_operation_effects(state, decision, operations, effects)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp operation_for(%{spec: %{operations: operations}}, name) do
    Enum.find(operations, &(&1.name == name))
  end

  defp put_operation_effect(state, operation, decision, name, arguments) do
    operation_request =
      Effect.OperationRequest.new!(
        name: name,
        arguments: arguments,
        request_id: state.request.request_id,
        loop_index: state.loop_index
      )

    effect = operation_effect(state, operation, operation_request, 0, 1)

    put_operation_effects(state, decision, [operation_request], [effect])
  end

  defp put_operation_effects(state, %Effect.LLMDecision{} = decision, operation_requests, effects) do
    planned_state = %{
      state
      | llm_result: decision,
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

  defp plan_operation_effect(state, name, arguments, index, batch_size) do
    case operation_for(state, name) do
      nil ->
        {:error, {:unknown_operation, name}}

      operation ->
        with :ok <- Agent.Spec.validate_operation_policy(state.spec, operation) do
          operation_request =
            Effect.OperationRequest.new!(
              name: name,
              arguments: arguments,
              request_id: state.request.request_id,
              loop_index: state.loop_index,
              metadata: %{"batch_index" => index, "batch_size" => batch_size}
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

    {idempotency_key, %{"batch_index" => index, "batch_size" => batch_size}}
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
end
