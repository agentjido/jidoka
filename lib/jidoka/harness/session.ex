defmodule Jidoka.Harness.Session do
  @moduledoc """
  Serializable harness envelope for running an agent across requests.

  A session is data. It stores the agent spec, request history, hibernated
  snapshots, pending review requests, and the latest result/error. It does not
  own processes or runtime capabilities.
  """

  alias Jidoka.Agent
  alias Jidoka.Id
  alias Jidoka.Review
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Schema
  alias Jidoka.Turn

  @schema_version 1
  @statuses [:new, :running, :hibernated, :waiting, :finished, :error]

  @schema Zoi.struct(
            __MODULE__,
            %{
              schema_version: Zoi.integer() |> Zoi.positive() |> Zoi.default(@schema_version),
              session_id: Schema.non_empty_string(),
              agent_id: Schema.non_empty_string(),
              spec: Zoi.lazy({Agent.Spec, :schema, []}),
              status: Schema.atom_enum(@statuses) |> Zoi.default(:new),
              requests: Zoi.array(Zoi.lazy({Turn.Request, :schema, []})) |> Zoi.default([]),
              snapshots: Zoi.array(Zoi.lazy({AgentSnapshot, :schema, []})) |> Zoi.default([]),
              result: Zoi.lazy({Turn.Result, :schema, []}) |> Zoi.nullish(),
              pending_reviews: Zoi.array(Zoi.lazy({Review.Request, :schema, []})) |> Zoi.default([]),
              error: Zoi.any() |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type status :: :new | :running | :hibernated | :waiting | :finished | :error
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a harness session."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Returns the current durable session schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Returns the possible harness session statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Builds a harness session from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, %__MODULE__{} = session} <- Schema.parse(@schema, attrs),
         :ok <- validate_schema_version(session) do
      {:ok, session}
    end
  end

  @doc "Builds a harness session and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, session} -> session
      {:error, reason} -> raise ArgumentError, "invalid harness session: #{inspect(reason)}"
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
        metadata: Keyword.get(opts, :metadata, %{})
      )
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

  @doc "Adds a snapshot and marks the session as hibernated."
  @spec put_snapshot(t(), AgentSnapshot.t()) :: t()
  def put_snapshot(%__MODULE__{snapshots: snapshots} = session, %AgentSnapshot{} = snapshot) do
    pending_reviews = pending_reviews_from_snapshot(snapshot)

    %__MODULE__{
      session
      | agent_id: snapshot.agent_id,
        snapshots: snapshots ++ [snapshot],
        pending_reviews: pending_reviews,
        status: snapshot_status(snapshot, pending_reviews),
        error: nil
    }
  end

  @doc "Adds a completed turn result and updates semantic agent state."
  @spec put_result(t(), Turn.Result.t()) :: t()
  def put_result(%__MODULE__{} = session, %Turn.Result{} = result) do
    %__MODULE__{
      session
      | result: result,
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

  @doc "Returns the most recent session snapshot, if one exists."
  @spec latest_snapshot(t()) :: AgentSnapshot.t() | nil
  def latest_snapshot(%__MODULE__{snapshots: snapshots}), do: List.last(snapshots)

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

  defp validate_schema_version(%__MODULE__{schema_version: @schema_version}), do: :ok

  defp validate_schema_version(%__MODULE__{schema_version: version}) do
    {:error, {:unsupported_session_schema_version, version, @schema_version}}
  end

  defp pending_reviews_from_snapshot(%AgentSnapshot{metadata: metadata}) do
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

  defp snapshot_status(%AgentSnapshot{cursor: %{phase: :review}}, _pending_reviews), do: :waiting
  defp snapshot_status(_snapshot, [_review | _rest]), do: :waiting
  defp snapshot_status(_snapshot, _pending_reviews), do: :hibernated
end
