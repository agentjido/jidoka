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
              prompt: Zoi.any() |> Zoi.nullish(),
              llm_result: Zoi.map() |> Zoi.nullish(),
              operation_plan: Zoi.map() |> Zoi.nullish(),
              pending_effect: Zoi.lazy({Effect.Intent, :schema, []}) |> Zoi.nullish(),
              result: Zoi.string() |> Zoi.nullish(),
              status: Zoi.enum([:running, :finished]) |> Zoi.default(:running),
              loop_index: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              journal: Zoi.lazy({Effect.Journal, :schema, []}),
              traces: Zoi.array(Zoi.map()) |> Zoi.default([]),
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
    |> Schema.put_default(:journal, Effect.Journal.new!())
  end

  @spec apply_effect_result(t(), Effect.Result.t()) :: {:ok, t()} | {:error, term()}
  def apply_effect_result(%__MODULE__{pending_effect: %{kind: :llm}} = state, %Effect.Result{
        status: :ok,
        output: output
      })
      when is_map(output) do
    case normalize_llm_output(output) do
      {:final, content} -> finish_turn(state, content)
      {:operation, name, arguments} -> plan_operation_turn(state, name, arguments)
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_effect_result(
        %__MODULE__{pending_effect: %{kind: :operation}} = state,
        %Effect.Result{
          status: :ok,
          output: output
        }
      ) do
    observation = %{
      role: :tool,
      content: inspect(output),
      operation: Schema.get_key(state.pending_effect.payload, :name),
      output: output
    }

    agent_state =
      state.agent_state
      |> append_message(observation)
      |> append_operation_result(observation)

    {:ok,
     %__MODULE__{
       state
       | pending_effect: nil,
         operation_plan: nil,
         agent_state: agent_state,
         traces: state.traces ++ [%{event: :operation_observed, operation: observation.operation}]
     }}
  end

  def apply_effect_result(_state, %Effect.Result{status: :error, output: output}),
    do: {:error, output}

  def apply_effect_result(state, result), do: {:error, {:unexpected_effect_result, state, result}}

  defp append_message(%Agent.State{messages: messages} = state, message) do
    %Agent.State{state | messages: messages ++ [message]}
  end

  defp append_operation_result(%Agent.State{operation_results: results} = state, result) do
    %Agent.State{state | operation_results: results ++ [result]}
  end

  defp normalize_llm_output(output) do
    case normalized_type(Schema.get_key(output, :type)) do
      "final" ->
        case Schema.get_key(output, :content) do
          content when is_binary(content) -> {:final, content}
          other -> {:error, {:invalid_final_content, other}}
        end

      "operation" ->
        name = Schema.get_key(output, :name)
        arguments = Schema.get_key(output, :arguments, %{})

        cond do
          not is_binary(name) -> {:error, {:invalid_operation_name, name}}
          not is_map(arguments) -> {:error, {:invalid_operation_arguments, arguments}}
          true -> {:operation, name, arguments}
        end

      type ->
        {:error, {:invalid_llm_decision_type, type}}
    end
  end

  defp normalized_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalized_type(type), do: type

  defp finish_turn(%__MODULE__{} = state, content) do
    message = %{role: :assistant, content: content}

    {:ok,
     %__MODULE__{
       state
       | pending_effect: nil,
         result: content,
         status: :finished,
         agent_state: append_message(state.agent_state, message),
         traces: state.traces ++ [%{event: :turn_finished}]
     }}
  end

  defp plan_operation_turn(%__MODULE__{} = state, name, arguments) do
    case operation_for(state, name) do
      nil ->
        {:error, {:unknown_operation, name}}

      operation ->
        {:ok, put_operation_effect(state, operation, name, arguments)}
    end
  end

  defp operation_for(%__MODULE__{spec: %{operations: operations}}, name) do
    Enum.find(operations, &(&1.name == name))
  end

  defp put_operation_effect(%__MODULE__{} = state, operation, name, arguments) do
    llm_result = %{type: :operation, name: name, arguments: arguments}

    payload = %{
      name: name,
      arguments: arguments,
      request_id: state.request.request_id,
      loop_index: state.loop_index
    }

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
      | llm_result: llm_result,
        operation_plan: payload,
        pending_effect: effect,
        traces: state.traces ++ [%{event: :effect_planned, kind: :operation, id: effect.id}]
    }
  end

  defp stable_key(parts) do
    :crypto.hash(:sha256, :erlang.term_to_binary(parts))
    |> Base.url_encode64(padding: false)
  end
end
