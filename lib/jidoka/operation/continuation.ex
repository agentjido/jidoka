defmodule Jidoka.Operation.Continuation do
  @moduledoc """
  Durable suspended work for one operation intent.

  A parent turn stores continuations when a workflow or subagent operation
  hibernates. Resume routes each continuation to the same intent and source.
  """

  alias Jidoka.Effect
  alias Jidoka.Schema

  @kinds [:workflow, :subagent]

  @schema Zoi.struct(
            __MODULE__,
            %{
              intent_id: Schema.non_empty_string(),
              operation: Schema.non_empty_string(),
              kind: Schema.atom_enum(@kinds),
              source: Schema.non_empty_string(),
              snapshot: Zoi.any(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type kind :: :workflow | :subagent
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a durable operation continuation."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a durable operation continuation."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    with :ok <- validate_snapshot(Schema.get_key(attrs, :kind), Schema.get_key(attrs, :snapshot)) do
      Schema.parse(@schema, attrs)
    end
  end

  @doc "Builds a durable operation continuation and raises for invalid data."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, continuation} -> continuation
      {:error, reason} -> raise ArgumentError, "invalid operation continuation: #{inspect(reason)}"
    end
  end

  @doc "Normalizes an operation continuation."
  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = continuation), do: new(continuation)
  def from_input(input), do: new(input)

  @doc "Normalizes an ordered continuation list."
  @spec list_from_input([t() | keyword() | map()]) :: {:ok, [t()]} | {:error, term()}
  def list_from_input(continuations) when is_list(continuations) do
    Enum.reduce_while(continuations, {:ok, []}, fn continuation, {:ok, acc} ->
      case from_input(continuation) do
        {:ok, continuation} -> {:cont, {:ok, [continuation | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, normalized} -> validate_unique_intents(Enum.reverse(normalized))
      {:error, _reason} = error -> error
    end)
  end

  def list_from_input(input), do: {:error, {:invalid_operation_continuations, input}}

  @doc "Returns the continuation for one exact operation route."
  @spec find([t()], Effect.Intent.t(), kind(), String.t()) :: {:ok, t()} | :none | {:error, term()}
  def find(continuations, %Effect.Intent{} = intent, kind, source)
      when is_list(continuations) and kind in @kinds and is_binary(source) do
    matches =
      Enum.filter(continuations, fn
        %__MODULE__{} = continuation ->
          continuation.intent_id == intent.id and continuation.operation == operation(intent) and
            continuation.kind == kind and continuation.source == source

        _continuation ->
          false
      end)

    case matches do
      [] -> :none
      [continuation] -> {:ok, continuation}
      _matches -> {:error, {:duplicate_operation_continuation, intent.id}}
    end
  end

  @doc "Returns true when one continuation resumes the exact intent and route."
  @spec resumes_intent?([t()], Effect.Intent.t(), kind(), String.t()) :: boolean()
  def resumes_intent?(continuations, %Effect.Intent{} = intent, kind, source)
      when is_list(continuations) and kind in @kinds and is_binary(source) do
    match?({:ok, %__MODULE__{}}, find(continuations, intent, kind, source))
  end

  @doc "Returns portable cursor data without the nested snapshot."
  @spec descriptor(t()) :: map()
  def descriptor(%__MODULE__{} = continuation) do
    %{
      "intent_id" => continuation.intent_id,
      "operation" => continuation.operation,
      "kind" => Atom.to_string(continuation.kind),
      "source" => continuation.source
    }
  end

  defp validate_snapshot(:workflow, %Jidoka.Workflow.Snapshot{}), do: :ok
  defp validate_snapshot("workflow", %Jidoka.Workflow.Snapshot{}), do: :ok
  defp validate_snapshot(:subagent, %Jidoka.Snapshot{}), do: :ok
  defp validate_snapshot("subagent", %Jidoka.Snapshot{}), do: :ok
  defp validate_snapshot(kind, snapshot), do: {:error, {:invalid_operation_continuation_snapshot, kind, snapshot}}

  defp validate_unique_intents(continuations) do
    duplicate_ids =
      continuations
      |> Enum.frequencies_by(& &1.intent_id)
      |> Enum.filter(fn {_intent_id, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if duplicate_ids == [] do
      {:ok, continuations}
    else
      {:error, {:duplicate_operation_continuation_intents, duplicate_ids}}
    end
  end

  defp operation(%Effect.Intent{payload: payload}) do
    Map.get(payload, :name) || Map.get(payload, "name")
  end
end
