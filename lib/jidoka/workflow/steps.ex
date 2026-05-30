defmodule Jidoka.Workflow.Steps do
  @moduledoc "Pure phase functions used by the MVP Runic turn workflow."

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Config
  alias Jidoka.Effect
  alias Jidoka.Turn

  @spec assemble_prompt(Turn.State.t()) :: Turn.State.t()
  def assemble_prompt(%Turn.State{} = state) do
    messages =
      [
        Agent.Message.system(state.spec.instructions),
        Agent.Message.user(state.request.input)
      ] ++ state.agent_state.messages

    messages = Enum.map(messages, &Agent.Message.to_map/1)

    operations =
      Enum.map(state.spec.operations, fn %Operation{} = operation ->
        metadata = operation.metadata || %{}

        %{
          name: operation.name,
          description: operation.description,
          idempotency: operation.idempotency,
          parameters_schema:
            Map.get(metadata, "parameters_schema") || Map.get(metadata, :parameters_schema)
        }
      end)

    prompt = %{
      model: Config.model_ref(state.spec.model),
      messages: messages,
      operations: operations,
      context: state.request.context,
      generation: state.spec.generation.params,
      loop_index: state.loop_index
    }

    %Turn.State{
      state
      | prompt: prompt
    }
    |> transition()
    |> transition_event(:prompt_assembled,
      agent_id: state.spec.id,
      request_id: state.request.request_id,
      loop_index: state.loop_index
    )
    |> Turn.Transition.commit()
  end

  @spec plan_model_effect(Turn.State.t()) :: Turn.State.t()
  def plan_model_effect(%Turn.State{} = state) do
    payload = %{
      model: state.spec.model,
      generation: state.spec.generation,
      prompt: state.prompt,
      request_id: state.request.request_id,
      loop_index: state.loop_index
    }

    effect =
      Effect.Intent.new(:llm, payload,
        idempotency: :idempotent,
        idempotency_key:
          stable_key([
            state.spec.id,
            state.request.request_id,
            :llm,
            state.loop_index,
            state.prompt
          ])
      )

    %Turn.State{
      state
      | pending_effects: [effect]
    }
    |> transition()
    |> transition_event(:effect_planned,
      agent_id: state.spec.id,
      request_id: state.request.request_id,
      loop_index: state.loop_index,
      effect_id: effect.id,
      effect_kind: :llm
    )
    |> Turn.Transition.commit()
  end

  defp transition(%Turn.State{} = state), do: Turn.Transition.new!(state)

  defp transition_event(%Turn.Transition{} = transition, event, attrs) do
    Turn.Transition.event(transition, event, attrs)
  end

  defp stable_key(parts) do
    :crypto.hash(:sha256, :erlang.term_to_binary(parts))
    |> Base.url_encode64(padding: false)
  end
end
