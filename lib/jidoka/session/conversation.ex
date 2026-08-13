defmodule Jidoka.Session.Conversation do
  @moduledoc """
  Canonical durable continuation state for one session.

  This record contains only completed conversation state. Active turn state
  stays in a snapshot until the turn completes successfully.
  """

  alias Jidoka.Agent
  alias Jidoka.Context
  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.Schema
  alias Jidoka.Turn

  @credential_words ~w(authorization credential credentials password secret token)
  @credential_compounds ~w(apikey privatekey)
  @continuation_revision_key "jidoka_continuation_revision"
  @fresh_conversation_key "jidoka_fresh_conversation"
  @snapshot_revision_key "jidoka_conversation_revision"

  @schema Zoi.struct(
            __MODULE__,
            %{
              agent_state:
                Zoi.lazy({Agent.State, :schema, []})
                |> Zoi.default(Agent.State.new!()),
              continuation_revision: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              turn_count: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              context_state:
                Zoi.map()
                |> Zoi.default(%{})
                |> Zoi.refine({Contract, :validate_safe_map, []}),
              last_completed_request_id: Schema.non_empty_string() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for canonical session conversation state."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds validated canonical conversation state."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ []) do
    with {:ok, %__MODULE__{} = conversation} <- Schema.parse(@schema, attrs),
         :ok <- validate_completion_identity(conversation),
         :ok <- validate_portable(conversation),
         :ok <- validate_no_credentials(conversation) do
      {:ok, conversation}
    end
  end

  @doc "Builds canonical conversation state and raises for invalid data."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs \\ []) do
    case new(attrs) do
      {:ok, conversation} -> conversation
      {:error, reason} -> raise ArgumentError, "invalid session conversation: #{inspect(reason)}"
    end
  end

  @doc "Normalizes an existing conversation, keyword list, or map."
  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = conversation), do: new(conversation)
  def from_input(input), do: new(input)

  @doc "Promotes one completed turn into a new continuation revision."
  @spec complete(t(), Turn.Request.t(), Turn.Result.t()) :: {:ok, t()} | {:error, term()}
  def complete(
        %__MODULE__{} = conversation,
        %Turn.Request{} = request,
        %Turn.Result{} = result
      ) do
    new(
      agent_state: result.agent_state,
      continuation_revision: conversation.continuation_revision + 1,
      turn_count: conversation.turn_count + 1,
      context_state: durable_context_state(Jidoka.Context.data(request.context)),
      last_completed_request_id: request.request_id
    )
  end

  @doc "Promotes a completed turn and raises for unsafe durable data."
  @spec complete!(t(), Turn.Request.t(), Turn.Result.t()) :: t()
  def complete!(%__MODULE__{} = conversation, %Turn.Request{} = request, %Turn.Result{} = result) do
    case complete(conversation, request, result) do
      {:ok, completed} -> completed
      {:error, reason} -> raise ArgumentError, "invalid completed conversation: #{inspect(reason)}"
    end
  end

  @doc "Builds one request from the current committed conversation revision."
  @spec prepare_request(t(), Turn.Request.t(), keyword()) ::
          {:ok, Turn.Request.t()} | {:error, term()}
  def prepare_request(%__MODULE__{} = conversation, %Turn.Request{} = request, opts) when is_list(opts) do
    with {:ok, fresh?} <- fresh_option(opts),
         {:ok, context} <- continuation_context(conversation, request, fresh?) do
      metadata =
        request.metadata
        |> Map.put(@continuation_revision_key, conversation.continuation_revision)
        |> Map.put(@fresh_conversation_key, fresh?)

      agent_state = if fresh?, do: Agent.State.new!(), else: conversation.agent_state

      {:ok, %Turn.Request{request | agent_state: agent_state, context: context, metadata: metadata}}
    end
  end

  @doc false
  @spec validate_request_revision(t(), Turn.Request.t(), String.t()) :: :ok | {:error, term()}
  def validate_request_revision(
        %__MODULE__{continuation_revision: current},
        %Turn.Request{metadata: metadata},
        session_id
      ) do
    case Map.get(metadata, @continuation_revision_key, Map.get(metadata, :jidoka_continuation_revision)) do
      nil -> :ok
      ^current -> :ok
      expected -> {:error, {:stale_conversation_revision, session_id, expected, current}}
    end
  end

  @doc false
  @spec request_revision(Turn.Request.t()) :: non_neg_integer() | nil
  def request_revision(%Turn.Request{metadata: metadata}) do
    Map.get(metadata, @continuation_revision_key, Map.get(metadata, :jidoka_continuation_revision))
  end

  @doc false
  @spec put_snapshot_revision(map(), Turn.Request.t()) :: map()
  def put_snapshot_revision(metadata, %Turn.Request{} = request) when is_map(metadata) do
    case request_revision(request) do
      revision when is_integer(revision) and revision >= 0 ->
        Map.put(metadata, @snapshot_revision_key, revision)

      _revision ->
        metadata
    end
  end

  @doc false
  @spec validate_snapshot_revision(t(), map(), String.t()) :: :ok | {:error, term()}
  def validate_snapshot_revision(
        %__MODULE__{continuation_revision: current},
        %{metadata: metadata},
        session_id
      ) do
    case Map.get(metadata, @snapshot_revision_key, Map.get(metadata, :jidoka_conversation_revision)) do
      nil ->
        :ok

      ^current ->
        :ok

      snapshot_revision ->
        {:error, {:stale_snapshot_conversation_revision, session_id, snapshot_revision, current}}
    end
  end

  @doc false
  @spec base_for_request(t(), Turn.Request.t() | nil) :: t()
  def base_for_request(%__MODULE__{} = conversation, %Turn.Request{metadata: metadata}) do
    if fresh_request_metadata?(metadata),
      do: new!(),
      else: conversation
  end

  def base_for_request(%__MODULE__{} = conversation, nil), do: conversation

  @doc false
  @spec next_revision(t(), Turn.Request.t() | nil) :: non_neg_integer()
  def next_revision(%__MODULE__{} = conversation, %Turn.Request{metadata: metadata}) do
    if fresh_request_metadata?(metadata), do: 1, else: conversation.continuation_revision + 1
  end

  def next_revision(%__MODULE__{} = conversation, nil), do: conversation.continuation_revision

  @doc false
  @spec from_legacy(Turn.Result.t() | map() | nil, [Turn.Request.t() | map()]) ::
          {:ok, t()} | {:error, term()}
  def from_legacy(result, requests) when is_list(requests) do
    request_id = completed_request_id(result) || fallback_completed_request_id(result, requests)
    completed_request = Enum.find(requests, &(request_id(&1) == request_id))
    turn_count = completed_turn_count(requests, request_id)

    new(
      agent_state: completed_agent_state(result),
      continuation_revision: turn_count,
      turn_count: turn_count,
      context_state: request_context(completed_request),
      last_completed_request_id: request_id
    )
  end

  @doc false
  @spec durable_context_state(map()) :: map()
  def durable_context_state(context) when is_map(context) do
    case durable_value(context) do
      {:keep, durable} -> durable
      :drop -> %{}
    end
  end

  defp fresh_option(opts) do
    case Keyword.get(opts, :fresh_conversation, false) do
      value when is_boolean(value) -> {:ok, value}
      value -> {:error, {:invalid_fresh_conversation_option, value}}
    end
  end

  defp continuation_context(conversation, request, fresh?) do
    previous = if fresh?, do: %{}, else: conversation.context_state
    data = Map.merge(previous, Context.data(request.context))

    Context.from_data(data,
      request_id: request.request_id,
      request_metadata: request.metadata
    )
  end

  defp fresh_request_metadata?(metadata) do
    Map.get(metadata, @fresh_conversation_key, Map.get(metadata, :jidoka_fresh_conversation, false))
  end

  defp validate_completion_identity(%__MODULE__{turn_count: 0, last_completed_request_id: nil}), do: :ok

  defp validate_completion_identity(%__MODULE__{turn_count: turn_count, last_completed_request_id: request_id})
       when turn_count > 0 and is_binary(request_id),
       do: :ok

  defp validate_completion_identity(%__MODULE__{} = conversation) do
    {:error,
     {:invalid_conversation_completion_identity, conversation.turn_count, conversation.last_completed_request_id}}
  end

  defp validate_portable(%__MODULE__{} = conversation) do
    conversation
    |> portable_term()
    |> Contract.validate_portable()
    |> case do
      :ok -> :ok
      {:error, reason} -> {:error, {:unsafe_conversation_state, reason}}
    end
  end

  defp portable_term(%_{} = struct), do: struct |> Map.from_struct() |> portable_term()

  defp portable_term(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {portable_term(key), portable_term(value)} end)
  end

  defp portable_term(list) when is_list(list), do: Enum.map(list, &portable_term/1)
  defp portable_term(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.map(&portable_term/1)
  defp portable_term(value), do: value

  defp validate_no_credentials(%__MODULE__{} = conversation) do
    case credential_path(portable_term(conversation), []) do
      nil -> :ok
      path -> {:error, {:credential_in_conversation, Enum.reverse(path)}}
    end
  end

  defp credential_path(map, path) when is_map(map) do
    Enum.find_value(map, fn {key, value} ->
      if credential_key?(key),
        do: [key | path],
        else: credential_path(value, [key | path])
    end)
  end

  defp credential_path(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.find_value(fn {value, index} -> credential_path(value, [index | path]) end)
  end

  defp credential_path(_value, _path), do: nil

  defp credential_key?(key) when is_atom(key) or is_binary(key) do
    words =
      key
      |> to_string()
      |> Macro.underscore()
      |> String.downcase()
      |> String.split(~r/[^a-z0-9]+/, trim: true)

    Enum.join(words, "") in @credential_compounds or
      Enum.any?(words, &(&1 in @credential_words))
  end

  defp credential_key?(_key), do: false

  defp durable_value(value)
       when is_function(value) or is_pid(value) or is_port(value) or is_reference(value),
       do: :drop

  defp durable_value(%_{} = struct), do: struct |> Map.from_struct() |> durable_value()

  defp durable_value(map) when is_map(map) do
    durable =
      Enum.reduce(map, %{}, fn {key, value}, acc ->
        with false <- credential_key?(key),
             {:keep, value} <- durable_value(value) do
          Map.put(acc, key, value)
        else
          _drop -> acc
        end
      end)

    {:keep, durable}
  end

  defp durable_value(list) when is_list(list) do
    durable =
      Enum.reduce(list, [], fn value, acc ->
        case durable_value(value) do
          {:keep, value} -> [value | acc]
          :drop -> acc
        end
      end)

    {:keep, Enum.reverse(durable)}
  end

  defp durable_value(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> durable_value()
  defp durable_value(value), do: {:keep, value}

  defp completed_agent_state(%Turn.Result{agent_state: agent_state}), do: agent_state

  defp completed_agent_state(%{} = result) do
    Schema.get_key(result, :agent_state, Agent.State.new!())
  end

  defp completed_agent_state(_result), do: Agent.State.new!()

  defp completed_request_id(%Turn.Result{metadata: metadata}), do: debug_request_id(metadata)

  defp completed_request_id(%{} = result) do
    result |> Schema.get_key(:metadata, %{}) |> debug_request_id()
  end

  defp completed_request_id(_result), do: nil

  defp fallback_completed_request_id(nil, _requests), do: nil
  defp fallback_completed_request_id(_result, requests), do: requests |> List.last() |> request_id()

  defp debug_request_id(metadata) do
    metadata
    |> Schema.get_key(:debug, %{})
    |> Schema.get_key(:request_id)
  end

  defp completed_turn_count(_requests, nil), do: 0

  defp completed_turn_count(requests, request_id) do
    case Enum.find_index(requests, &(request_id(&1) == request_id)) do
      nil -> 1
      index -> index + 1
    end
  end

  defp request_id(%Turn.Request{request_id: request_id}), do: request_id
  defp request_id(%{} = request), do: Schema.get_key(request, :request_id)
  defp request_id(_request), do: nil

  defp request_context(%Turn.Request{context: context}) do
    context |> Jidoka.Context.data() |> durable_context_state()
  end

  defp request_context(%{} = request) do
    case Schema.get_key(request, :context) do
      %Jidoka.Context{} = context -> context |> Jidoka.Context.data() |> durable_context_state()
      %{} = context -> context |> Schema.get_key(:data, %{}) |> durable_context_state()
      _context -> %{}
    end
  end

  defp request_context(_request), do: %{}
end
