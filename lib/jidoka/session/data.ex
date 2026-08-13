defmodule Jidoka.Session.Data do
  @moduledoc """
  Serializable session envelope for running an agent across requests.

  A session is data. It stores the agent spec, request history, hibernated
  snapshots, pending review requests, and the latest result/error. It does not
  own processes or runtime capabilities.
  """

  alias Jidoka.Agent
  alias Jidoka.Session.Conversation
  alias Jidoka.Session.Environment
  alias Jidoka.Session.Lease
  alias Jidoka.Session.Lineage
  alias Jidoka.Id
  alias Jidoka.Review
  alias Jidoka.Snapshot
  alias Jidoka.Schema
  alias Jidoka.Turn

  @schema_version 3
  @supported_schema_versions [1, 2, 3]
  @statuses [:new, :running, :hibernated, :waiting, :finished, :cancelled, :error]

  @schema Zoi.struct(
            __MODULE__,
            %{
              schema_version: Zoi.integer() |> Zoi.positive() |> Zoi.default(@schema_version),
              revision: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              session_id: Schema.non_empty_string(),
              agent_id: Schema.non_empty_string(),
              spec: Zoi.lazy({Agent.Spec, :schema, []}),
              status: Schema.atom_enum(@statuses) |> Zoi.default(:new),
              conversation:
                Zoi.lazy({Conversation, :schema, []})
                |> Zoi.default(Conversation.new!()),
              requests: Zoi.array(Zoi.lazy({Turn.Request, :schema, []})) |> Zoi.default([]),
              snapshots: Zoi.array(Zoi.lazy({Snapshot, :schema, []})) |> Zoi.default([]),
              result: Zoi.lazy({Turn.Result, :schema, []}) |> Zoi.nullish(),
              pending_reviews: Zoi.array(Zoi.lazy({Review.Request, :schema, []})) |> Zoi.default([]),
              error: Zoi.any() |> Zoi.nullish(),
              lease: Zoi.lazy({Lease, :schema, []}) |> Zoi.nullish(),
              lineage: Zoi.lazy({Lineage, :schema, []}) |> Zoi.nullish(),
              environment: Zoi.lazy({Environment, :schema, []}) |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type status :: :new | :running | :hibernated | :waiting | :finished | :cancelled | :error
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a durable session."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Returns the current durable session schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Returns the possible durable session statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Builds a durable session from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- attrs |> Schema.normalize_attrs() |> put_legacy_conversation(),
         {:ok, %__MODULE__{} = session} <- Schema.parse(@schema, attrs),
         {:ok, conversation} <- Conversation.from_input(session.conversation),
         :ok <- validate_schema_version(session) do
      {:ok, %__MODULE__{session | conversation: conversation}}
    end
  end

  @doc "Builds a durable session and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, session} -> session
      {:error, reason} -> raise ArgumentError, "invalid durable session: #{inspect(reason)}"
    end
  end

  @doc "Normalizes an existing session, keyword list, or map."
  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = session), do: new(session)
  def from_input(input), do: new(input)

  @doc "Starts durable session data for an agent specification."
  @spec start(Agent.Spec.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(%Agent.Spec{} = spec, opts \\ []) do
    with {:ok, session_id} <- session_id(opts) do
      new(
        schema_version: @schema_version,
        session_id: session_id,
        agent_id: spec.id,
        spec: spec,
        status: :new,
        conversation: Conversation.new!(),
        metadata: Keyword.get(opts, :metadata, %{})
      )
    end
  end

  @doc "Builds a new session from a copied, safe snapshot and lineage data."
  @spec fork(t(), Snapshot.t(), Lineage.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def fork(
        %__MODULE__{} = source,
        %Snapshot{} = snapshot,
        %Lineage{} = lineage,
        opts \\ []
      ) do
    with :ok <- validate_fork_agent(source, snapshot),
         {:ok, fork_session_id} <- session_id(opts),
         :ok <- validate_distinct_fork_id(source, fork_session_id),
         {:ok, fork} <-
           new(
             schema_version: @schema_version,
             session_id: fork_session_id,
             agent_id: source.agent_id,
             spec: source.spec,
             conversation: source.conversation,
             requests: requests_through_snapshot(source, snapshot),
             lineage: lineage,
             environment: Keyword.get(opts, :environment, snapshot.environment),
             metadata: Map.merge(source.metadata, Keyword.get(opts, :metadata, %{}))
           ) do
      {:ok, put_snapshot(fork, snapshot)}
    end
  end

  @doc "Adds a request and marks the session as running."
  @spec put_request(t(), Turn.Request.t()) :: t()
  def put_request(%__MODULE__{requests: requests} = session, %Turn.Request{} = request) do
    %__MODULE__{
      session
      | requests: requests ++ [request],
        status: :running,
        error: nil
    }
  end

  @doc "Adds active lease ownership to a running session."
  @spec put_lease(t(), Lease.t()) :: t()
  def put_lease(%__MODULE__{} = session, %Lease{} = lease) do
    %__MODULE__{session | lease: lease, status: :running}
  end

  @doc "Removes active lease ownership from a session."
  @spec clear_lease(t()) :: t()
  def clear_lease(%__MODULE__{} = session), do: %__MODULE__{session | lease: nil}

  @doc "Increments the durable session revision."
  @spec bump_revision(t()) :: t()
  def bump_revision(%__MODULE__{revision: revision} = session) do
    %__MODULE__{session | revision: revision + 1}
  end

  @doc "Returns portable extension state from durable session metadata."
  @spec extension_state(t()) :: map()
  def extension_state(%__MODULE__{metadata: metadata}) do
    Map.get(metadata, "extension_state", Map.get(metadata, :extension_state, %{}))
  end

  @doc "Stores validated namespaced extension state in durable session metadata."
  @spec put_extension_state(t(), map()) :: {:ok, t()} | {:error, term()}
  def put_extension_state(%__MODULE__{} = session, states) when is_map(states) do
    case Jidoka.ExecutionEnvironment.Contract.validate_safe_map(states) do
      :ok -> {:ok, %{session | metadata: Map.put(session.metadata, "extension_state", states)}}
      {:error, reason} -> {:error, {:invalid_extension_state, reason}}
    end
  end

  @doc "Records a durable in-run checkpoint while lease ownership stays active."
  @spec put_durable_checkpoint(t(), Snapshot.t()) :: t()
  def put_durable_checkpoint(%__MODULE__{} = session, %Snapshot{} = snapshot) do
    snapshots = upsert_snapshot(session.snapshots, snapshot)

    %__MODULE__{
      session
      | agent_id: snapshot.agent_id,
        snapshots: snapshots,
        environment: snapshot.environment || session.environment,
        status: :running,
        error: nil
    }
  end

  @doc "Adds a snapshot and marks the session as hibernated."
  @spec put_snapshot(t(), Snapshot.t()) :: t()
  def put_snapshot(%__MODULE__{snapshots: snapshots} = session, %Snapshot{} = snapshot) do
    pending_reviews = pending_reviews_from_snapshot(snapshot)

    %__MODULE__{
      session
      | agent_id: snapshot.agent_id,
        snapshots: upsert_snapshot(snapshots, snapshot),
        environment: snapshot.environment || session.environment,
        pending_reviews: pending_reviews,
        status: snapshot_status(snapshot, pending_reviews),
        error: nil
    }
  end

  @doc "Adds a completed turn result and updates semantic agent state."
  @spec put_result(t(), Turn.Result.t()) :: t()
  def put_result(%__MODULE__{} = session, %Turn.Result{} = result) do
    request = List.last(session.requests)
    conversation = complete_conversation(session.conversation, request, result)

    %__MODULE__{
      session
      | conversation: conversation,
        result: result,
        pending_reviews: [],
        status: :finished,
        error: nil
    }
  end

  @doc "Records a session error and marks the session as failed."
  @spec put_error(t(), term()) :: t()
  def put_error(%__MODULE__{} = session, reason) do
    %__MODULE__{session | status: :error, error: reason}
  end

  @doc "Records typed cancellation evidence and marks the session as cancelled."
  @spec put_cancellation(t(), Jidoka.Cancellation.t() | term()) :: t()
  def put_cancellation(%__MODULE__{} = session, cancellation) do
    %__MODULE__{session | status: :cancelled, error: cancellation}
  end

  @doc "Records portable execution-environment state."
  @spec put_environment(t(), Environment.t() | nil) :: t()
  def put_environment(%__MODULE__{} = session, nil), do: %__MODULE__{session | environment: nil}

  def put_environment(%__MODULE__{} = session, %Environment{} = environment) do
    %__MODULE__{session | environment: environment}
  end

  @doc "Returns the most recent session snapshot, if one exists."
  @spec latest_snapshot(t()) :: Snapshot.t() | nil
  def latest_snapshot(%__MODULE__{snapshots: snapshots}), do: List.last(snapshots)

  @doc "Merges snapshot evidence without adding duplicate snapshot ids."
  @spec merge_snapshots([Snapshot.t()], [Snapshot.t()]) :: [Snapshot.t()]
  def merge_snapshots(existing, additions) when is_list(existing) and is_list(additions) do
    Enum.reduce(additions, existing, &upsert_snapshot(&2, &1))
  end

  defp session_id(opts) do
    case Keyword.fetch(opts, :session_id) do
      {:ok, session_id} when is_binary(session_id) and session_id != "" ->
        {:ok, session_id}

      {:ok, session_id} ->
        {:error, {:invalid_session_id, session_id}}

      :error ->
        Id.generate("sess", Keyword.get(opts, :id_generator))
    end
  end

  defp validate_fork_agent(
         %__MODULE__{agent_id: agent_id},
         %Snapshot{agent_id: agent_id}
       ),
       do: :ok

  defp validate_fork_agent(%__MODULE__{} = source, %Snapshot{} = snapshot) do
    {:error, {:snapshot_agent_mismatch, source.agent_id, snapshot.agent_id}}
  end

  defp validate_distinct_fork_id(%__MODULE__{session_id: session_id}, session_id) do
    {:error, {:fork_session_id_matches_source, session_id}}
  end

  defp validate_distinct_fork_id(%__MODULE__{}, _fork_session_id), do: :ok

  defp requests_through_snapshot(%__MODULE__{requests: requests}, %Snapshot{
         turn_state: %{request: %Turn.Request{request_id: request_id} = snapshot_request}
       }) do
    case Enum.find_index(requests, &(&1.request_id == request_id)) do
      nil -> [snapshot_request]
      index -> Enum.take(requests, index + 1)
    end
  end

  defp validate_schema_version(%__MODULE__{schema_version: version})
       when version in @supported_schema_versions,
       do: :ok

  defp validate_schema_version(%__MODULE__{schema_version: version}) do
    {:error, {:unsupported_session_schema_version, version, @schema_version}}
  end

  defp complete_conversation(%Conversation{} = conversation, %Turn.Request{} = request, result),
    do: Conversation.complete!(conversation, request, result)

  defp complete_conversation(nil, %Turn.Request{} = request, result),
    do: Conversation.complete!(Conversation.new!(), request, result)

  defp complete_conversation(conversation, nil, _result), do: conversation || Conversation.new!()

  defp put_legacy_conversation(attrs) when is_map(attrs) do
    if has_key?(attrs, :conversation) do
      {:ok, attrs}
    else
      result = Schema.get_key(attrs, :result)
      requests = Schema.get_key(attrs, :requests, [])

      with {:ok, conversation} <- Conversation.from_legacy(result, requests) do
        {:ok, Map.put(attrs, :conversation, conversation)}
      end
    end
  end

  defp put_legacy_conversation(attrs), do: {:ok, attrs}

  defp has_key?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp pending_reviews_from_snapshot(%Snapshot{metadata: metadata}) do
    case Map.get(metadata, "pending_review", Map.get(metadata, :pending_review)) do
      nil -> []
      %Review.Request{} = request -> [request]
      request -> normalize_pending_review(request)
    end
  end

  defp normalize_pending_review(request) do
    case Review.Request.from_input(request) do
      {:ok, request} -> [request]
      {:error, _reason} -> []
    end
  end

  defp snapshot_status(%Snapshot{cursor: %{phase: :review}}, _pending_reviews), do: :waiting
  defp snapshot_status(_snapshot, [_review | _rest]), do: :waiting
  defp snapshot_status(_snapshot, _pending_reviews), do: :hibernated

  defp upsert_snapshot(snapshots, %Snapshot{} = snapshot) do
    case Enum.find_index(snapshots, &(&1.snapshot_id == snapshot.snapshot_id)) do
      nil -> snapshots ++ [snapshot]
      index -> List.replace_at(snapshots, index, snapshot)
    end
  end
end
