defmodule Jidoka.Runtime.Spine.Steps do
  @moduledoc "Pure phase functions used by the Runic turn workflow."

  alias Jidoka.Agent
  alias Jidoka.Config
  alias Jidoka.ContextWindow
  alias Jidoka.Effect
  alias Jidoka.Id
  alias Jidoka.Operation.Registry
  alias Jidoka.Portable
  alias Jidoka.Turn

  @doc "Assembles prompt data and plans memory effects without external calls."
  @spec assemble_prompt(Turn.State.t()) :: Turn.State.t()
  def assemble_prompt(%Turn.State{} = state) do
    %Turn.State{} = state = append_request_message(state)
    %Turn.State{} = state = append_memory_recalled(state)

    prefix =
      [
        Agent.Message.system(state.plan.spec.instructions),
        memory_message(state.plan.spec.memory, state.memory)
      ]
      |> Enum.reject(&is_nil/1)

    operations = state.plan.spec.operations |> Registry.new!() |> Registry.prompt_operations()

    prompt = %{
      model: Config.model_ref(state.plan.spec.model),
      operations: operations,
      result: result_contract(state.plan.spec.result),
      memory: memory_contract(state.memory),
      context: Jidoka.Context.data(state.request.context),
      generation: state.plan.spec.generation.params,
      loop_index: state.loop_index
    }

    state
    |> project_context(prompt, prefix)
    |> append_prompt_event()
  end

  @doc "Plans the next model effect from assembled turn state."
  @spec plan_model_effect(Turn.State.t()) :: Turn.State.t()
  def plan_model_effect(%Turn.State{context_projection_error: error} = state) when not is_nil(error),
    do: state

  def plan_model_effect(%Turn.State{} = state) do
    payload = %{
      agent_id: state.plan.spec.id,
      model: state.plan.spec.model,
      generation: state.plan.spec.generation,
      prompt: state.prompt,
      request_id: state.request.request_id,
      loop_index: state.loop_index
    }

    effect =
      Effect.Intent.new(:llm, payload,
        idempotency: :idempotent,
        idempotency_key:
          stable_key([
            state.plan.spec.id,
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
      agent_id: state.plan.spec.id,
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

  defp project_context(%Turn.State{} = state, prompt, prefix) do
    case ContextWindow.project(
           prompt,
           prefix,
           state.agent_state.messages,
           state.plan.context_policy,
           state.request.request_id
         ) do
      {:ok, projected_prompt, evidence} ->
        %Turn.State{
          state
          | prompt: projected_prompt,
            context_projection: evidence,
            context_projection_error: nil
        }

      {:error, reason, evidence} ->
        %Turn.State{
          state
          | prompt: nil,
            context_projection: evidence,
            context_projection_error: reason,
            diagnostics: state.diagnostics ++ [reason]
        }
    end
  end

  defp append_prompt_event(%Turn.State{} = state) do
    transition =
      state
      |> transition()
      |> maybe_append_compaction_event()
      |> transition_event(:prompt_assembled,
        agent_id: state.plan.spec.id,
        request_id: state.request.request_id,
        loop_index: state.loop_index,
        data: %{context_projection: state.context_projection}
      )

    Turn.Transition.commit(transition)
  end

  defp maybe_append_compaction_event(
         %Turn.Transition{state: %Turn.State{context_projection: %{status: :compacted}}} = transition
       ) do
    state = transition.state

    transition_event(transition, :context_compacted,
      agent_id: state.plan.spec.id,
      request_id: state.request.request_id,
      loop_index: state.loop_index,
      data: state.context_projection
    )
  end

  defp maybe_append_compaction_event(%Turn.Transition{} = transition), do: transition

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
      agent_id: state.plan.spec.id,
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
      entries: Enum.map(memory.entries, &memory_entry_contract/1),
      count: length(memory.entries)
    }
  end

  defp memory_entry_contract(entry) do
    %{
      id: entry.id,
      agent_id: entry.agent_id,
      session_id: entry.session_id,
      content: entry.content,
      metadata: Portable.project(entry.metadata)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp append_request_message(%Turn.State{} = state) do
    message =
      state.request
      |> request_message()
      |> Map.put(:id, Id.stable("msg", [state.request.request_id, :user]))
      |> Map.put(:request_id, state.request.request_id)

    %Turn.State{
      state
      | agent_state: Agent.Transcript.append(state.agent_state, message)
    }
  end

  defp request_message(%Turn.Request{content: []} = request),
    do: Agent.Message.user(request.input)

  defp request_message(%Turn.Request{content: content}), do: Agent.Message.user(content)

  defp stable_key(parts) do
    :crypto.hash(:sha256, :erlang.term_to_binary(parts))
    |> Base.url_encode64(padding: false)
  end
end
