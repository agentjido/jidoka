defmodule Jidoka.Effect.OperationGroup do
  @moduledoc """
  Durable manifest for one ordered group of operation intents.

  The manifest keeps model call order separate from runtime completion order.
  Started and completed identifiers are stored in manifest order so snapshots
  remain deterministic across serial and parallel execution.
  """

  alias Jidoka.Effect
  alias Jidoka.Schema

  @statuses [:planned, :running, :completed]

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Schema.non_empty_string(),
              intent_ids: Zoi.array(Schema.non_empty_string()),
              started_intent_ids: Zoi.array(Schema.non_empty_string()) |> Zoi.default([]),
              completed_intent_ids: Zoi.array(Schema.non_empty_string()) |> Zoi.default([]),
              status: Schema.atom_enum(@statuses) |> Zoi.default(:planned)
            },
            coerce: true
          )

  @type status :: :planned | :running | :completed
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the operation-group schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a deterministic manifest from an ordered, nonempty intent group."
  @spec new([Effect.Intent.t()]) :: {:ok, t()} | {:error, term()}
  def new(intents) when is_list(intents) and intents != [] do
    with true <- Enum.all?(intents, &match?(%Effect.Intent{kind: :operation}, &1)),
         intent_ids = Enum.map(intents, & &1.id),
         true <- length(Enum.uniq(intent_ids)) == length(intent_ids) do
      Schema.parse(@schema, %{
        id: Jidoka.Id.stable("op_group", intent_ids),
        intent_ids: intent_ids
      })
    else
      false -> {:error, {:invalid_operation_group, intents}}
    end
  end

  def new(intents), do: {:error, {:invalid_operation_group, intents}}

  @doc "Builds an operation-group manifest and raises for invalid input."
  @spec new!([Effect.Intent.t()]) :: t()
  def new!(intents) do
    case new(intents) do
      {:ok, group} -> group
      {:error, reason} -> raise ArgumentError, "invalid operation group: #{inspect(reason)}"
    end
  end

  @doc "Marks one manifest intent as started."
  @spec start(t(), Effect.Intent.t() | String.t()) :: {:ok, t()} | {:error, term()}
  def start(%__MODULE__{} = group, intent_or_id) do
    with {:ok, intent_id} <- member_id(group, intent_or_id) do
      started = ordered_add(group, group.started_intent_ids, intent_id)
      status = if group.completed_intent_ids == group.intent_ids, do: :completed, else: :running
      {:ok, %__MODULE__{group | started_intent_ids: started, status: status}}
    end
  end

  @doc "Marks one started manifest intent as completed."
  @spec complete(t(), Effect.Intent.t() | String.t()) :: {:ok, t()} | {:error, term()}
  def complete(%__MODULE__{} = group, intent_or_id) do
    intent_id = intent_id(intent_or_id)

    with {:ok, ^intent_id} <- member_id(group, intent_id),
         true <- intent_id in group.started_intent_ids do
      completed = ordered_add(group, group.completed_intent_ids, intent_id)
      status = if completed == group.intent_ids, do: :completed, else: :running
      {:ok, %__MODULE__{group | completed_intent_ids: completed, status: status}}
    else
      false -> {:error, {:operation_group_intent_not_started, intent_id}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns true when the manifest includes the intent."
  @spec member?(t(), Effect.Intent.t() | String.t()) :: boolean()
  def member?(%__MODULE__{} = group, intent_or_id),
    do: intent_id(intent_or_id) in group.intent_ids

  defp member_id(group, intent_or_id) do
    intent_id = intent_id(intent_or_id)
    if intent_id in group.intent_ids, do: {:ok, intent_id}, else: {:error, {:operation_group_unknown_intent, intent_id}}
  end

  defp ordered_add(group, ids, intent_id) do
    selected = MapSet.new([intent_id | ids])
    Enum.filter(group.intent_ids, &MapSet.member?(selected, &1))
  end

  defp intent_id(%Effect.Intent{id: id}), do: id
  defp intent_id(id) when is_binary(id), do: id
  defp intent_id(other), do: inspect(other)
end
