defmodule Jidoka.Workflow.Steps do
  @moduledoc "Pure phase functions used by the MVP Runic turn workflow."

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Config
  alias Jidoka.Effect
  alias Jidoka.Turn

  @spec assemble_prompt(Turn.State.t()) :: Turn.State.t()
  def assemble_prompt(%Turn.State{} = state) do
    messages =
      [
        %{role: :system, content: state.spec.instructions},
        %{role: :user, content: state.request.input}
      ] ++ state.agent_state.messages

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
      | prompt: prompt,
        traces: state.traces ++ [%{event: :prompt_assembled, loop_index: state.loop_index}]
    }
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
      | pending_effect: effect,
        traces: state.traces ++ [%{event: :effect_planned, kind: :llm, id: effect.id}]
    }
  end

  defp stable_key(parts) do
    :crypto.hash(:sha256, :erlang.term_to_binary(parts))
    |> Base.url_encode64(padding: false)
  end
end
