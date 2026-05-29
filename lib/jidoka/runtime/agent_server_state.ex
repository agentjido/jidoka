defmodule Jidoka.Runtime.AgentServerState do
  @moduledoc """
  Formal Jidoka state contract stored inside a process-hosted Jido agent.

  `Jido.AgentServer` expects conventional top-level fields like `:status`,
  `:last_answer`, and `:error`. Jidoka keeps those fields for Jido
  compatibility and stores its typed turn/runtime state under `:jidoka`.
  """

  alias Jidoka.Agent
  alias Jidoka.Error
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Schema
  alias Jidoka.Turn

  @state_key :jidoka

  @schema Zoi.struct(
            __MODULE__,
            %{
              status:
                Zoi.enum([:idle, :running, :completed, :hibernated, :failed])
                |> Zoi.default(:idle),
              request_id: Schema.non_empty_string() |> Zoi.nullish(),
              agent_state: Zoi.lazy({Agent.State, :schema, []}),
              result: Zoi.lazy({Turn.Result, :schema, []}) |> Zoi.nullish(),
              snapshot: Zoi.lazy({AgentSnapshot, :schema, []}) |> Zoi.nullish(),
              error: Zoi.any() |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec state_key() :: atom()
  def state_key, do: @state_key

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ []) do
    attrs
    |> Schema.normalize_attrs()
    |> Schema.put_default(:agent_state, Agent.State.new!())
    |> then(&Schema.parse(@schema, &1))
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs \\ []), do: Schema.parse!(@schema, prepare_attrs(attrs), "agent server state")

  @spec from_input(t() | keyword() | map() | nil) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = state), do: new(state)
  def from_input(nil), do: new()
  def from_input(input), do: new(input)

  @spec from_jido_state(map()) :: {:ok, t()} | {:error, term()}
  def from_jido_state(jido_state) when is_map(jido_state) do
    jido_state
    |> Schema.get_key(@state_key, %{})
    |> from_input()
  end

  @spec from_jido_state!(map()) :: t()
  def from_jido_state!(jido_state) when is_map(jido_state) do
    case from_jido_state(jido_state) do
      {:ok, state} -> state
      {:error, _reason} -> new!()
    end
  end

  @spec current_agent_state(map()) :: Agent.State.t()
  def current_agent_state(jido_state) when is_map(jido_state) do
    jido_state
    |> from_jido_state!()
    |> Map.fetch!(:agent_state)
  end

  @spec completed(Turn.Result.t(), Turn.Request.t()) :: t()
  def completed(%Turn.Result{} = result, %Turn.Request{} = request) do
    new!(
      status: :completed,
      request_id: request.request_id,
      agent_state: result.agent_state,
      result: result,
      snapshot: nil,
      error: nil
    )
  end

  @spec hibernated(AgentSnapshot.t(), Turn.Request.t()) :: t()
  def hibernated(%AgentSnapshot{} = snapshot, %Turn.Request{} = request) do
    new!(
      status: :hibernated,
      request_id: request.request_id,
      agent_state: snapshot.turn_state.agent_state,
      result: nil,
      snapshot: snapshot,
      error: nil
    )
  end

  @spec failed(term(), Agent.State.t(), keyword() | map()) :: t()
  def failed(reason, %Agent.State{} = agent_state \\ Agent.State.new!(), context \\ %{}) do
    new!(
      status: :failed,
      agent_state: agent_state,
      result: nil,
      snapshot: nil,
      error: normalize_error(reason, context)
    )
  end

  @spec to_jido_state(t()) :: map()
  def to_jido_state(%__MODULE__{} = state) do
    Map.put(
      %{
        status: jido_status(state),
        last_request_id: state.request_id,
        last_answer: answer(state),
        error: state.error
      },
      @state_key,
      state
    )
  end

  @spec to_run_result(t()) ::
          {:ok, Turn.Result.t()} | {:hibernate, AgentSnapshot.t()} | {:error, term()}
  def to_run_result(%__MODULE__{status: :completed, result: %Turn.Result{} = result}),
    do: {:ok, result}

  def to_run_result(%__MODULE__{status: :hibernated, snapshot: %AgentSnapshot{} = snapshot}),
    do: {:hibernate, snapshot}

  def to_run_result(%__MODULE__{status: :failed, error: error, request_id: request_id}),
    do: {:error, normalize_error(error, %{operation: :run_turn, request_id: request_id})}

  def to_run_result(%__MODULE__{} = state) do
    {:error,
     Error.normalize({:unexpected_jidoka_agent_state, state},
       operation: :run_turn,
       phase: :agent_server,
       request_id: state.request_id
     )}
  end

  defp prepare_attrs(attrs) do
    attrs
    |> Schema.normalize_attrs()
    |> Schema.put_default(:agent_state, Agent.State.new!())
  end

  defp jido_status(%__MODULE__{status: :completed}), do: :completed
  defp jido_status(%__MODULE__{status: :failed}), do: :failed
  defp jido_status(%__MODULE__{status: :hibernated}), do: :waiting
  defp jido_status(%__MODULE__{status: :running}), do: :working
  defp jido_status(%__MODULE__{}), do: :idle

  defp answer(%__MODULE__{result: %Turn.Result{content: content}}), do: content
  defp answer(%__MODULE__{}), do: nil

  defp normalize_error(reason, context) do
    context =
      context
      |> normalize_context()
      |> Map.put_new(:operation, :run_turn)
      |> Map.put_new(:phase, :agent_server)

    Error.normalize(reason, context)
  end

  defp normalize_context(context) when is_map(context), do: context
  defp normalize_context(context) when is_list(context), do: Map.new(context)
  defp normalize_context(_context), do: %{}
end
