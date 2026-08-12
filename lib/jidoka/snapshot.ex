defmodule Jidoka.Snapshot do
  @moduledoc """
  Serializable semantic snapshot for hibernate/resume.

  Durable snapshot strings are authenticated with an HMAC signing secret from
  `:jidoka, :snapshot_signing_secret` or `JIDOKA_SNAPSHOT_SIGNING_SECRET`.
  """

  alias Jidoka.Context
  alias Jidoka.Event
  alias Jidoka.Id
  alias Jidoka.Review
  alias Jidoka.Schema
  alias Jidoka.Session.Environment
  alias Jidoka.Snapshot.Codec
  alias Jidoka.Turn

  @schema_version 2
  @supported_schema_versions [1, 2]
  @forkable_phases [:after_prompt, :before_effect, :review, :wait]

  @schema Zoi.struct(
            __MODULE__,
            %{
              schema_version: Zoi.integer() |> Zoi.positive() |> Zoi.default(@schema_version),
              snapshot_id: Schema.non_empty_string(),
              agent_id: Schema.non_empty_string(),
              cursor: Zoi.lazy({Turn.Cursor, :schema, []}),
              turn_state: Zoi.lazy({Turn.State, :schema, []}),
              environment: Zoi.lazy({Environment, :schema, []}) |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a durable agent snapshot."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Returns the current snapshot schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Builds a durable agent snapshot from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs =
      attrs
      |> Schema.normalize_attrs()
      |> normalize_portable_events()

    with {:ok, %__MODULE__{} = snapshot} <- Schema.parse(@schema, attrs),
         :ok <- validate_schema_version(snapshot) do
      {:ok, snapshot}
    end
  end

  @doc "Builds an agent snapshot and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, snapshot} -> snapshot
      {:error, reason} -> raise ArgumentError, "invalid agent snapshot: #{inspect(reason)}"
    end
  end

  @doc "Normalizes a snapshot struct or authenticated serialized snapshot."
  @spec from_input(t() | String.t()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = snapshot), do: new(snapshot)
  def from_input(input) when is_binary(input), do: deserialize(input)
  def from_input(_input), do: {:error, :unsafe_snapshot_input}

  @doc """
  Serializes a snapshot into an opaque durable string.

  The format is intentionally internal to Jidoka. It preserves Elixir data
  fidelity across hibernate/resume while the schema version remains the public
  compatibility boundary.
  """
  @spec serialize(t()) :: {:ok, String.t()} | {:error, term()}
  def serialize(snapshot_input) do
    with {:ok, %__MODULE__{} = snapshot} <- from_input(snapshot_input) do
      Codec.serialize(snapshot)
    end
  end

  @doc "Serializes and signs a snapshot, or raises if serialization fails."
  @spec serialize!(t()) :: String.t()
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
  def deserialize(input) when is_binary(input) do
    with {:ok, term} <- Codec.deserialize(input),
         {:ok, %__MODULE__{} = snapshot} <- new(term) do
      {:ok, snapshot}
    end
  end

  def deserialize(_input), do: {:error, :invalid_snapshot_serialization}

  @doc "Builds a phase-boundary snapshot from the current turn state."
  @spec from_turn_state(Turn.State.t(), Turn.Cursor.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def from_turn_state(%Turn.State{} = state, %Turn.Cursor{} = cursor, opts \\ []) do
    with {:ok, snapshot_id} <- snapshot_id(opts) do
      state = sanitize_state(state)

      new(
        schema_version: @schema_version,
        snapshot_id: snapshot_id,
        agent_id: state.spec.id,
        cursor: %Turn.Cursor{cursor | loop_index: state.loop_index},
        turn_state: state,
        environment: Keyword.get(opts, :environment),
        metadata: snapshot_metadata(state, opts)
      )
    end
  end

  @doc "Builds a phase-boundary snapshot and raises on invalid data."
  @spec from_turn_state!(Turn.State.t(), Turn.Cursor.t(), keyword()) :: t()
  def from_turn_state!(%Turn.State{} = state, %Turn.Cursor{} = cursor, opts \\ []) do
    case from_turn_state(state, cursor, opts) do
      {:ok, snapshot} ->
        snapshot

      {:error, reason} ->
        raise ArgumentError, "invalid agent snapshot: #{inspect(reason)}"
    end
  end

  @doc """
  Copies a hibernation snapshot for a new session fork.

  The copied snapshot keeps the exact turn state and effect journal. It gets a
  new snapshot id and records the source in metadata. Only resumable phase
  boundaries can be forked.
  """
  @spec fork(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def fork(%__MODULE__{} = snapshot, opts) when is_list(opts) do
    with :ok <- validate_forkable_cursor(snapshot),
         {:ok, snapshot_id} <- snapshot_id(opts) do
      metadata =
        snapshot.metadata
        |> Map.put("fork", %{
          "source_snapshot_id" => snapshot.snapshot_id,
          "parent_session_id" => Keyword.fetch!(opts, :parent_session_id),
          "root_session_id" => Keyword.fetch!(opts, :root_session_id)
        })

      new(%__MODULE__{snapshot | snapshot_id: snapshot_id, metadata: metadata})
    end
  rescue
    KeyError -> {:error, :missing_snapshot_fork_lineage}
  end

  def fork(_snapshot, _opts), do: {:error, :unsafe_snapshot_fork_input}

  @doc "Returns the phase boundaries that support safe session forks."
  @spec forkable_phases() :: [atom()]
  def forkable_phases, do: @forkable_phases

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

  defp validate_forkable_cursor(%__MODULE__{cursor: %Turn.Cursor{phase: phase}})
       when phase in @forkable_phases,
       do: :ok

  defp validate_forkable_cursor(%__MODULE__{snapshot_id: snapshot_id, cursor: cursor}) do
    {:error, {:snapshot_not_forkable, snapshot_id, cursor.phase}}
  end

  defp validate_schema_version(%__MODULE__{schema_version: version})
       when version in @supported_schema_versions,
       do: :ok

  defp validate_schema_version(%__MODULE__{schema_version: version}) do
    {:error, {:unsupported_snapshot_schema_version, version, @schema_version}}
  end

  defp normalize_portable_events(%{turn_state: turn_state} = attrs) do
    %{attrs | turn_state: normalize_turn_state_events(turn_state)}
  end

  defp normalize_portable_events(%{"turn_state" => turn_state} = attrs) do
    %{attrs | "turn_state" => normalize_turn_state_events(turn_state)}
  end

  defp normalize_portable_events(attrs), do: attrs

  defp normalize_turn_state_events(%Turn.State{} = state), do: state

  defp normalize_turn_state_events(%{} = turn_state) do
    turn_state
    |> normalize_event_list(:events)
    |> normalize_event_list("events")
  end

  defp normalize_turn_state_events(turn_state), do: turn_state

  defp normalize_event_list(%{} = turn_state, key) do
    case Map.fetch(turn_state, key) do
      {:ok, events} when is_list(events) ->
        Map.put(turn_state, key, Enum.map(events, &normalize_event/1))

      _other ->
        turn_state
    end
  end

  defp normalize_event(%Event{} = event), do: event

  defp normalize_event(%{} = event) do
    event
    |> normalize_event_data(:data)
    |> normalize_event_data("data")
  end

  defp normalize_event(event), do: event

  defp normalize_event_data(%{} = event, key) do
    case Map.fetch(event, key) do
      {:ok, data} when is_map(data) -> Map.put(event, key, normalize_existing_atom_keys(data))
      _other -> event
    end
  end

  defp normalize_existing_atom_keys(data) do
    Map.new(data, fn {key, value} -> {existing_atom_key(key), value} end)
  end

  defp existing_atom_key(key) when is_atom(key), do: key

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp existing_atom_key(key), do: key

  defp snapshot_metadata(%Turn.State{} = state, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case state.pending_interrupt do
      nil -> metadata
      %Review.Interrupt{} = interrupt -> Map.put(metadata, "pending_review", Review.Request.from_interrupt!(interrupt))
    end
  end

  defp sanitize_state(%Turn.State{request: %Turn.Request{} = request} = state) do
    request = %Turn.Request{request | context: Context.sanitize(request.context)}
    %Turn.State{state | request: request}
  end
end
