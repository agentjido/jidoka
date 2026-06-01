defmodule Jidoka.Effect.Journal do
  @moduledoc "Intent/result journal used to make effects replayable."

  alias Jidoka.Schema
  alias Jidoka.Effect

  @schema Zoi.struct(
            __MODULE__,
            %{
              intents: Zoi.map(Zoi.string(), Zoi.lazy({Effect.Intent, :schema, []})) |> Zoi.default(%{}),
              results: Zoi.map(Zoi.string(), Zoi.lazy({Effect.Result, :schema, []})) |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ []), do: Schema.parse(@schema, attrs)

  @spec new!(keyword() | map()) :: t()
  def new!(attrs \\ []), do: Schema.parse!(@schema, attrs, "effect journal")

  def put_intent(%__MODULE__{} = journal, %Effect.Intent{} = intent) do
    %__MODULE__{journal | intents: Map.put_new(journal.intents, intent.id, intent)}
  end

  def put_result(%__MODULE__{} = journal, %Effect.Result{} = result) do
    %__MODULE__{journal | results: Map.put(journal.results, result.intent_id, result)}
  end

  def result_for(%__MODULE__{results: results}, %Effect.Intent{id: id}), do: Map.get(results, id)

  @spec intent_for(t(), Effect.Intent.t() | String.t()) :: Effect.Intent.t() | nil
  def intent_for(%__MODULE__{intents: intents}, %Effect.Intent{id: id}), do: Map.get(intents, id)
  def intent_for(%__MODULE__{intents: intents}, id) when is_binary(id), do: Map.get(intents, id)

  @spec intent_recorded?(t(), Effect.Intent.t() | String.t()) :: boolean()
  def intent_recorded?(%__MODULE__{} = journal, intent_or_id) do
    not is_nil(intent_for(journal, intent_or_id))
  end

  @spec incomplete_intent?(t(), Effect.Intent.t()) :: boolean()
  def incomplete_intent?(%__MODULE__{} = journal, %Effect.Intent{} = intent) do
    intent_recorded?(journal, intent) and is_nil(result_for(journal, intent))
  end
end
