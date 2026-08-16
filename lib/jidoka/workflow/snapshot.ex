defmodule Jidoka.Workflow.Snapshot do
  @moduledoc """
  Serializable state for one suspended declarative workflow.

  Runtime-only context is not stored. Pass fresh runtime context when the
  workflow resumes. The binary format is not authenticated. Deserialize it
  only from trusted application storage.
  """

  alias Jidoka.Workflow.Loop.Cursor
  alias Jidoka.Workflow.Suspension

  @schema_version 2
  @enforce_keys [
    :schema_version,
    :workflow,
    :workflow_id,
    :input,
    :context,
    :steps,
    :outcomes
  ]
  defstruct [
    :schema_version,
    :workflow,
    :workflow_id,
    :input,
    :context,
    :steps,
    :outcomes
  ]

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          workflow: module(),
          workflow_id: String.t(),
          input: map(),
          context: map(),
          steps: map(),
          outcomes: map()
        }

  @doc "Returns the current workflow snapshot schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Serializes a workflow snapshot to Erlang external term format."
  @spec serialize(t()) :: {:ok, binary()} | {:error, term()}
  def serialize(%__MODULE__{schema_version: @schema_version} = snapshot) do
    with {:ok, %Cursor{}} <- cursor(snapshot),
         :ok <- validate_portable(snapshot) do
      {:ok, :erlang.term_to_binary(snapshot, [:compressed])}
    end
  rescue
    exception -> {:error, {:snapshot_serialize_failed, exception}}
  end

  def serialize(%__MODULE__{schema_version: version}),
    do: {:error, {:unsupported_snapshot_version, version}}

  @doc "Restores a workflow snapshot from Erlang external term format."
  @spec deserialize(binary()) :: {:ok, t()} | {:error, term()}
  def deserialize(binary) when is_binary(binary) do
    binary
    |> :erlang.binary_to_term([:safe])
    |> normalize()
  rescue
    exception -> {:error, {:snapshot_deserialize_failed, exception}}
  end

  def deserialize(other), do: {:error, {:invalid_workflow_snapshot, other}}

  @doc false
  @spec normalize(t()) :: {:ok, t()} | {:error, term()}
  def normalize(%__MODULE__{schema_version: @schema_version} = snapshot) do
    with {:ok, %Cursor{}} <- cursor(snapshot),
         :ok <- validate_portable(snapshot),
         do: {:ok, snapshot}
  end

  def normalize(%__MODULE__{schema_version: 1} = snapshot), do: upgrade_v1(snapshot)

  def normalize(%__MODULE__{schema_version: version}),
    do: {:error, {:unsupported_snapshot_version, version}}

  def normalize(other), do: {:error, {:invalid_workflow_snapshot, other}}

  @doc "Returns the single suspended cursor owned by snapshot outcomes."
  @spec cursor(t()) :: {:ok, Cursor.t()} | {:error, term()}
  def cursor(%__MODULE__{outcomes: outcomes}) do
    case Suspension.cursor(outcomes) do
      {:ok, %Cursor{} = cursor} -> {:ok, cursor}
      {:ok, nil} -> {:error, :workflow_snapshot_missing_suspension}
      {:error, _reason} = error -> error
    end
  end

  defp upgrade_v1(%__MODULE__{} = legacy) do
    legacy_cursor = legacy |> Map.to_list() |> Keyword.get(:loop_cursor)

    with :ok <- validate_portable(legacy),
         {:ok, outcomes} <- normalize_v1_outcomes(legacy.outcomes, legacy_cursor),
         snapshot = %__MODULE__{
           schema_version: @schema_version,
           workflow: legacy.workflow,
           workflow_id: legacy.workflow_id,
           input: legacy.input,
           context: legacy.context,
           steps: legacy.steps,
           outcomes: outcomes
         },
         {:ok, %Cursor{}} <- cursor(snapshot) do
      {:ok, snapshot}
    end
  end

  defp normalize_v1_outcomes(outcomes, nil) do
    case Suspension.cursor(outcomes) do
      {:ok, %Cursor{}} -> {:ok, outcomes}
      {:ok, nil} -> {:error, :workflow_snapshot_missing_suspension}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_v1_outcomes(outcomes, %Cursor{} = legacy_cursor) do
    case Suspension.cursor(outcomes) do
      {:ok, nil} ->
        {:ok, Map.put(outcomes, legacy_cursor.step, %{status: :suspended, cursor: legacy_cursor})}

      {:ok, ^legacy_cursor} ->
        {:ok, outcomes}

      {:ok, outcome_cursor} ->
        {:error, {:workflow_snapshot_cursor_conflict, outcome_cursor, legacy_cursor}}

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_v1_outcomes(_outcomes, legacy_cursor),
    do: {:error, {:invalid_workflow_snapshot_cursor, legacy_cursor}}

  defp validate_portable(value), do: validate_portable(value, [])

  defp validate_portable(value, path)
       when is_function(value) or is_pid(value) or is_port(value) or is_reference(value) do
    {:error, {:non_serializable_workflow_snapshot_value, Enum.reverse(path), portable_type(value)}}
  end

  defp validate_portable(tuple, path) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> validate_portable(path)
  end

  defp validate_portable(%_{} = struct, path) do
    struct
    |> Map.from_struct()
    |> validate_portable(path)
  end

  defp validate_portable(%{} = map, path) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      with :ok <- validate_portable(key, [:key | path]),
           :ok <- validate_portable(value, [key | path]) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_portable(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case validate_portable(value, [index | path]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_portable(_value, _path), do: :ok

  defp portable_type(value) when is_function(value), do: :function
  defp portable_type(value) when is_pid(value), do: :pid
  defp portable_type(value) when is_port(value), do: :port
  defp portable_type(value) when is_reference(value), do: :reference
end
