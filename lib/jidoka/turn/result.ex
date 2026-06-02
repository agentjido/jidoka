defmodule Jidoka.Turn.Result do
  @moduledoc "Final app-facing result of one Jidoka turn."

  alias Jidoka.Schema
  alias Jidoka.Agent
  alias Jidoka.Config
  alias Jidoka.Effect
  alias Jidoka.Turn

  @schema Zoi.struct(
            __MODULE__,
            %{
              content: Zoi.string(),
              value: Zoi.any() |> Zoi.nullish(),
              agent_state: Zoi.lazy({Agent.State, :schema, []}),
              journal: Zoi.lazy({Effect.Journal, :schema, []}),
              events: Zoi.array(Zoi.lazy({Jidoka.Event, :schema, []})) |> Zoi.default([]),
              usage: Zoi.map() |> Zoi.default(%{}),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "turn result")

  @spec from_turn_state!(Turn.State.t()) :: t()
  def from_turn_state!(%Turn.State{status: :finished, result: content} = state) do
    new!(
      content: content,
      value: state.result_value,
      agent_state: state.agent_state,
      journal: state.journal,
      events: state.events,
      usage: Jidoka.Usage.from_journal(state.journal),
      metadata: %{debug: debug_metadata(state)}
    )
  end

  defp debug_metadata(%Turn.State{} = state) do
    %{
      request_id: state.request.request_id,
      agent_id: state.spec.id,
      model: Config.model_ref(state.spec.model),
      input: state.request.input,
      context_keys: context_keys(state.request.context),
      prompt: prompt_debug(state.prompt),
      diagnostics: state.diagnostics,
      started_at_ms: state.started_at_ms
    }
  end

  defp prompt_debug(nil), do: nil

  defp prompt_debug(%{} = prompt) do
    operations = Map.get(prompt, :operations, Map.get(prompt, "operations", []))

    %{
      model: Map.get(prompt, :model, Map.get(prompt, "model")),
      loop_index: Map.get(prompt, :loop_index, Map.get(prompt, "loop_index")),
      messages: Map.get(prompt, :messages, Map.get(prompt, "messages", [])),
      message_count: length(Map.get(prompt, :messages, Map.get(prompt, "messages", []))),
      operations: operations,
      operation_names: Enum.map(operations, &operation_name/1),
      operation_count: length(operations),
      result: Map.get(prompt, :result, Map.get(prompt, "result")),
      memory: Map.get(prompt, :memory, Map.get(prompt, "memory")),
      generation: Map.get(prompt, :generation, Map.get(prompt, "generation"))
    }
  end

  defp operation_name(%{} = operation), do: Map.get(operation, :name, Map.get(operation, "name"))
  defp operation_name(_operation), do: nil

  defp context_keys(%{} = context) do
    context
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp context_keys(_context), do: []
end
