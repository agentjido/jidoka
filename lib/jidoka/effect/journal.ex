defmodule Jidoka.Effect.Journal do
  @moduledoc "Intent/result journal used to make effects replayable."

  alias Jidoka.Schema
  alias Jidoka.Effect
  alias Jidoka.Policy.Decision

  @schema Zoi.struct(
            __MODULE__,
            %{
              intents: Zoi.map(Zoi.string(), Zoi.lazy({Effect.Intent, :schema, []})) |> Zoi.default(%{}),
              results: Zoi.map(Zoi.string(), Zoi.lazy({Effect.Result, :schema, []})) |> Zoi.default(%{}),
              policy_decisions: Zoi.map(Zoi.string(), Zoi.lazy({Decision, :schema, []})) |> Zoi.default(%{}),
              operation_groups:
                Zoi.map(Zoi.string(), Zoi.lazy({Effect.OperationGroup, :schema, []}))
                |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for an effect journal."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds an empty or restored effect journal."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ []), do: Schema.parse(@schema, attrs)

  @doc "Builds an effect journal and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs \\ []), do: Schema.parse!(@schema, attrs, "effect journal")

  @doc "Records an intent by its stable identifier."
  @spec put_intent(t(), Effect.Intent.t()) :: t()
  def put_intent(%__MODULE__{} = journal, %Effect.Intent{} = intent) do
    %__MODULE__{journal | intents: Map.put_new(journal.intents, intent.id, intent)}
  end

  @doc "Records an effect result by its intent identifier."
  @spec put_result(t(), Effect.Result.t()) :: t()
  def put_result(%__MODULE__{} = journal, %Effect.Result{} = result) do
    %__MODULE__{journal | results: Map.put(journal.results, result.intent_id, result)}
  end

  @doc "Records one durable operation-group manifest."
  @spec put_operation_group(t(), Effect.OperationGroup.t()) :: t()
  def put_operation_group(%__MODULE__{} = journal, %Effect.OperationGroup{} = group) do
    %__MODULE__{journal | operation_groups: Map.put(journal.operation_groups, group.id, group)}
  end

  @doc "Returns a recorded operation-group manifest by identifier."
  @spec operation_group(t(), String.t()) :: Effect.OperationGroup.t() | nil
  def operation_group(%__MODULE__{operation_groups: groups}, group_id) when is_binary(group_id),
    do: Map.get(groups, group_id)

  @doc "Returns the recorded result for an intent, if it exists."
  @spec result_for(t(), Effect.Intent.t()) :: Effect.Result.t() | nil
  def result_for(%__MODULE__{results: results}, %Effect.Intent{id: id}), do: Map.get(results, id)

  @doc "Records one authoritative policy decision by effect identifier."
  @spec put_policy_decision(t(), Effect.Intent.t(), Decision.t()) :: t()
  def put_policy_decision(%__MODULE__{} = journal, %Effect.Intent{id: id}, %Decision{} = decision) do
    %__MODULE__{journal | policy_decisions: Map.put_new(journal.policy_decisions, id, decision)}
  end

  @doc "Returns the policy decision recorded for an effect."
  @spec policy_decision_for(t(), Effect.Intent.t()) :: Decision.t() | nil
  def policy_decision_for(%__MODULE__{policy_decisions: decisions}, %Effect.Intent{id: id}),
    do: Map.get(decisions, id)

  @doc "Returns a recorded intent by intent value or identifier."
  @spec intent_for(t(), Effect.Intent.t() | String.t()) :: Effect.Intent.t() | nil
  def intent_for(%__MODULE__{intents: intents}, %Effect.Intent{id: id}), do: Map.get(intents, id)
  def intent_for(%__MODULE__{intents: intents}, id) when is_binary(id), do: Map.get(intents, id)

  @doc "Returns true when the journal contains the intent."
  @spec intent_recorded?(t(), Effect.Intent.t() | String.t()) :: boolean()
  def intent_recorded?(%__MODULE__{} = journal, intent_or_id) do
    not is_nil(intent_for(journal, intent_or_id))
  end

  @doc "Returns true when an intent is recorded without a result."
  @spec incomplete_intent?(t(), Effect.Intent.t()) :: boolean()
  def incomplete_intent?(%__MODULE__{} = journal, %Effect.Intent{} = intent) do
    intent_recorded?(journal, intent) and is_nil(result_for(journal, intent))
  end
end
