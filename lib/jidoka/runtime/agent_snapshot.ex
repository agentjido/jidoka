defmodule Jidoka.Runtime.AgentSnapshot do
  @moduledoc "Serializable semantic snapshot for hibernate/resume."

  alias Jidoka.Id
  alias Jidoka.Runtime.Review
  alias Jidoka.Schema
  alias Jidoka.Turn

  @schema_version 1
  @serialized_prefix "jidoka:snapshot:v1:"

  @schema Zoi.struct(
            __MODULE__,
            %{
              schema_version: Zoi.integer() |> Zoi.positive() |> Zoi.default(@schema_version),
              snapshot_id: Schema.non_empty_string(),
              agent_id: Schema.non_empty_string(),
              cursor: Zoi.lazy({Turn.Cursor, :schema, []}),
              turn_state: Zoi.lazy({Turn.State, :schema, []}),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, %__MODULE__{} = snapshot} <- Schema.parse(@schema, attrs),
         :ok <- validate_schema_version(snapshot) do
      {:ok, snapshot}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, snapshot} -> snapshot
      {:error, reason} -> raise ArgumentError, "invalid agent snapshot: #{inspect(reason)}"
    end
  end

  @spec from_input(t() | keyword() | map() | String.t()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = snapshot), do: new(snapshot)
  def from_input(input) when is_binary(input), do: deserialize(input)
  def from_input(input), do: new(input)

  @doc """
  Serializes a snapshot into an opaque durable string.

  The format is intentionally internal to Jidoka. It preserves Elixir data
  fidelity across hibernate/resume while the schema version remains the public
  compatibility boundary.
  """
  @spec serialize(t() | keyword() | map()) :: {:ok, String.t()} | {:error, term()}
  def serialize(snapshot_input) do
    with {:ok, %__MODULE__{} = snapshot} <- from_input(snapshot_input),
         :ok <- validate_portable(snapshot) do
      data =
        snapshot
        |> :erlang.term_to_binary()
        |> Base.url_encode64(padding: false)

      {:ok, @serialized_prefix <> data}
    end
  end

  @spec serialize!(t() | keyword() | map()) :: String.t()
  def serialize!(snapshot_input) do
    case serialize(snapshot_input) do
      {:ok, serialized} -> serialized
      {:error, reason} -> raise ArgumentError, "invalid serializable snapshot: #{inspect(reason)}"
    end
  end

  @doc """
  Restores a snapshot produced by `serialize/1`.
  """
  @spec deserialize(String.t()) :: {:ok, t()} | {:error, term()}
  def deserialize(@serialized_prefix <> encoded) do
    with {:ok, binary} <- Base.url_decode64(encoded, padding: false),
         {:ok, term} <- safe_binary_to_term(binary),
         {:ok, %__MODULE__{} = snapshot} <- new(term) do
      {:ok, snapshot}
    end
  end

  def deserialize(_input), do: {:error, :invalid_snapshot_serialization}

  @spec from_turn_state(Turn.State.t(), Turn.Cursor.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def from_turn_state(%Turn.State{} = state, %Turn.Cursor{} = cursor, opts \\ []) do
    with {:ok, snapshot_id} <- snapshot_id(opts) do
      new(
        schema_version: @schema_version,
        snapshot_id: snapshot_id,
        agent_id: state.spec.id,
        cursor: %Turn.Cursor{cursor | loop_index: state.loop_index},
        turn_state: state,
        metadata: snapshot_metadata(state, opts)
      )
    end
  end

  @spec from_turn_state!(Turn.State.t(), Turn.Cursor.t(), keyword()) :: t()
  def from_turn_state!(%Turn.State{} = state, %Turn.Cursor{} = cursor, opts \\ []) do
    case from_turn_state(state, cursor, opts) do
      {:ok, snapshot} ->
        snapshot

      {:error, reason} ->
        raise ArgumentError, "invalid agent snapshot: #{inspect(reason)}"
    end
  end

  defp snapshot_id(opts) do
    case Keyword.fetch(opts, :snapshot_id) do
      {:ok, snapshot_id} when is_binary(snapshot_id) and snapshot_id != "" ->
        {:ok, snapshot_id}

      {:ok, snapshot_id} ->
        {:error, {:invalid_snapshot_id, snapshot_id}}

      :error ->
        Id.generate("snap", Keyword.get(opts, :id_generator))
    end
  end

  defp validate_schema_version(%__MODULE__{schema_version: @schema_version}), do: :ok

  defp validate_schema_version(%__MODULE__{schema_version: version}) do
    {:error, {:unsupported_snapshot_schema_version, version, @schema_version}}
  end

  defp snapshot_metadata(%Turn.State{} = state, opts) do
    opts
    |> Keyword.get(:metadata, %{})
    |> Review.put_pending_metadata(state.pending_interrupt)
  end

  defp safe_binary_to_term(binary) when is_binary(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    error -> {:error, {:invalid_snapshot_serialization, error}}
  end

  defp validate_portable(value), do: validate_portable(value, [])

  defp validate_portable(value, path)
       when is_function(value) or is_pid(value) or is_port(value) or is_reference(value) do
    {:error, {:non_serializable_snapshot_value, Enum.reverse(path), portable_type(value)}}
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
