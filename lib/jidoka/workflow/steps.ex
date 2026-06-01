defmodule Jidoka.Workflow.Steps do
  @moduledoc "Pure phase functions used by the Runic turn workflow."

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Config
  alias Jidoka.Effect
  alias Jidoka.Turn

  @spec assemble_prompt(Turn.State.t()) :: Turn.State.t()
  def assemble_prompt(%Turn.State{} = state) do
    %Turn.State{} = state = append_memory_recalled(state)

    messages =
      [
        Agent.Message.system(state.spec.instructions),
        memory_message(state.spec.memory, state.memory)
      ]
      |> Enum.reject(&is_nil/1)
      |> Kernel.++(state.request.agent_state.messages)
      |> Kernel.++([Agent.Message.user(state.request.input)])
      |> Kernel.++(current_turn_messages(state))

    messages = Enum.map(messages, &Agent.Message.to_map/1)

    operations =
      Enum.map(state.spec.operations, fn %Operation{} = operation ->
        metadata = operation.metadata || %{}

        %{
          name: operation.name,
          description: operation.description,
          idempotency: operation.idempotency,
          parameters_schema: Map.get(metadata, "parameters_schema") || Map.get(metadata, :parameters_schema)
        }
      end)

    prompt = %{
      model: Config.model_ref(state.spec.model),
      messages: messages,
      operations: operations,
      result: result_contract(state.spec.result),
      memory: memory_contract(state.memory),
      compactions: Enum.map(state.compactions, &Jidoka.projection/1),
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
      agent_id: state.spec.id,
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

  defp result_contract(nil), do: nil

  defp result_contract(%Agent.Spec.Result{} = result) do
    %{
      schema?: true,
      schema: result_schema_contract(result.schema),
      max_repairs: result.max_repairs,
      metadata: result.metadata
    }
  end

  defp result_schema_contract(%Zoi.Types.Map{fields: fields}) when is_list(fields) do
    fields =
      Map.new(fields, fn {field, schema} ->
        {to_string(field), result_schema_contract(schema)}
      end)

    %{
      type: "object",
      required: Map.keys(fields),
      fields: fields
    }
  end

  defp result_schema_contract(%Zoi.Types.Array{inner: inner}) do
    %{type: "array", items: result_schema_contract(inner)}
  end

  defp result_schema_contract(%Zoi.Types.String{}), do: %{type: "string"}
  defp result_schema_contract(%Zoi.Types.Number{}), do: %{type: "number"}
  defp result_schema_contract(%Zoi.Types.Integer{}), do: %{type: "integer"}
  defp result_schema_contract(%Zoi.Types.Float{}), do: %{type: "float"}
  defp result_schema_contract(%Zoi.Types.Boolean{}), do: %{type: "boolean"}
  defp result_schema_contract(%Zoi.Types.Atom{}), do: %{type: "atom"}
  defp result_schema_contract(%Zoi.Types.Any{}), do: %{type: "any"}
  defp result_schema_contract(%_{}), do: %{schema?: true}

  defp append_memory_recalled(%Turn.State{memory: nil} = state), do: state
  defp append_memory_recalled(%Turn.State{memory: %{entries: []}} = state), do: state

  defp append_memory_recalled(%Turn.State{} = state) do
    state
    |> transition()
    |> transition_event(:memory_recalled,
      agent_id: state.spec.id,
      request_id: state.request.request_id,
      loop_index: state.loop_index,
      data: memory_contract(state.memory)
    )
    |> Turn.Transition.commit()
  end

  defp memory_message(_policy, nil), do: nil
  defp memory_message(_policy, %{entries: []}), do: nil
  defp memory_message(%Agent.Spec.Memory{inject: :context}, _memory), do: nil

  defp memory_message(_policy, memory) do
    content =
      memory.entries
      |> Enum.map_join("\n", fn entry -> "- #{entry.content}" end)

    Agent.Message.system("Relevant memory:\n" <> content)
  end

  defp memory_contract(nil), do: nil

  defp memory_contract(memory) do
    %{
      entries: Enum.map(memory.entries, &Jidoka.projection/1),
      count: length(memory.entries)
    }
  end

  defp current_turn_messages(%Turn.State{} = state) do
    Enum.drop(state.agent_state.messages, length(state.request.agent_state.messages))
  end

  defp stable_key(parts) do
    :crypto.hash(:sha256, :erlang.term_to_binary(parts))
    |> Base.url_encode64(padding: false)
  end
end
