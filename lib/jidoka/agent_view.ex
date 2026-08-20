defmodule Jidoka.AgentView do
  @moduledoc """
  Surface-neutral UI projection contract for a Jidoka agent.

  `AgentView` is not a Phoenix view and does not render HTML. It is a small
  application-facing projection that LiveView, CLI examples, channels, tests, or
  jobs can use to keep UI state separate from the durable agent runtime.

  The struct is projection-only. It stores no pid, transcript persistence,
  provider client, process state, or adapter data.
  """

  alias Jidoka.Error
  alias Jidoka.Projection
  alias Jidoka.Schema
  alias Jidoka.AgentView.Events
  alias Jidoka.AgentView.Runner
  alias Jidoka.Event
  alias Jidoka.Turn

  @statuses [:idle, :running, :error, :interrupted, :handoff]

  @schema Zoi.struct(
            __MODULE__,
            %{
              agent_id: Zoi.string() |> Zoi.default("agent-default"),
              conversation_id: Zoi.string() |> Zoi.default("default"),
              runtime_context: Zoi.map() |> Zoi.default(%{}),
              visible_messages: Zoi.array(Zoi.map()) |> Zoi.default([]),
              streaming_message: Zoi.map() |> Zoi.nullish(),
              events: Zoi.array(Zoi.map()) |> Zoi.default([]),
              status: Schema.atom_enum(@statuses) |> Zoi.default(:idle),
              error: Zoi.any() |> Zoi.nullish(),
              error_text: Zoi.string() |> Zoi.nullish(),
              outcome: Zoi.any() |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type input :: term()
  @type status :: :idle | :running | :error | :interrupted | :handoff

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Prepares external resources before the initial view is built."
  @callback prepare(input()) :: :ok | {:error, term()}

  @doc "Returns the agent module, specification, or plan for a view input."
  @callback agent_module(input()) :: module() | Jidoka.Agent.Spec.t() | Jidoka.Turn.Plan.t()

  @doc "Returns the durable conversation identifier for a view input."
  @callback conversation_id(input()) :: String.t()

  @doc "Returns the runtime agent identifier for a view input."
  @callback agent_id(input()) :: String.t()

  @doc "Returns application context data for turns started by the view."
  @callback runtime_context(input()) :: map()

  @doc false
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts \\ []) do
    agent = Keyword.get(opts, :agent)

    quote bind_quoted: [agent: agent] do
      @behaviour Jidoka.AgentView

      @jidoka_agent_view_agent agent

      @impl Jidoka.AgentView
      @spec prepare(Jidoka.AgentView.input()) :: :ok | {:error, term()}
      def prepare(_input), do: :ok

      @impl Jidoka.AgentView
      @spec agent_module(Jidoka.AgentView.input()) ::
              module() | Jidoka.Agent.Spec.t() | Jidoka.Turn.Plan.t()
      def agent_module(_input) do
        case @jidoka_agent_view_agent do
          nil ->
            raise ArgumentError,
                  "#{inspect(__MODULE__)} must pass `agent:` to `use Jidoka.AgentView` or override agent_module/1"

          module ->
            module
        end
      end

      @impl Jidoka.AgentView
      @spec conversation_id(Jidoka.AgentView.input()) :: String.t()
      def conversation_id(input), do: Jidoka.AgentView.default_conversation_id(input)

      @impl Jidoka.AgentView
      @spec agent_id(Jidoka.AgentView.input()) :: String.t()
      def agent_id(input),
        do: Jidoka.AgentView.default_agent_id(agent_module(input), conversation_id(input))

      @impl Jidoka.AgentView
      @spec runtime_context(Jidoka.AgentView.input()) :: map()
      def runtime_context(input),
        do: Jidoka.AgentView.default_runtime_context(input, conversation_id(input))

      @doc false
      @spec initial(Jidoka.AgentView.input(), keyword()) ::
              {:ok, Jidoka.AgentView.t()} | {:error, term()}
      def initial(input \\ %{}, opts \\ []), do: Jidoka.AgentView.initial(__MODULE__, input, opts)

      @doc false
      @spec before_turn(Jidoka.AgentView.t(), String.t()) :: Jidoka.AgentView.t()
      def before_turn(view, message), do: Jidoka.AgentView.before_turn(view, message)

      @doc false
      @spec before_turn(Jidoka.AgentView.t(), String.t(), String.t()) :: Jidoka.AgentView.t()
      def before_turn(view, message, request_id),
        do: Jidoka.AgentView.before_turn(view, message, request_id)

      @doc false
      @spec activate_request(Jidoka.AgentView.t(), String.t()) :: Jidoka.AgentView.t()
      def activate_request(view, request_id), do: Jidoka.AgentView.activate_request(view, request_id)

      @doc false
      @spec after_turn(
              Jidoka.AgentView.t(),
              {:ok, Jidoka.Turn.Result.t()}
              | {:hibernate, Jidoka.Snapshot.t()}
              | {:error, term()}
            ) :: Jidoka.AgentView.t()
      def after_turn(view, result), do: Jidoka.AgentView.after_turn(view, result)

      @doc false
      @spec after_turn(
              Jidoka.AgentView.t(),
              {:ok, Jidoka.Turn.Result.t()}
              | {:hibernate, Jidoka.Snapshot.t()}
              | {:error, term()},
              String.t()
            ) :: Jidoka.AgentView.t()
      def after_turn(view, result, request_id),
        do: Jidoka.AgentView.after_turn(view, result, request_id)

      @doc false
      @spec apply_event(Jidoka.AgentView.t(), Jidoka.Event.t() | map()) :: Jidoka.AgentView.t()
      def apply_event(view, event), do: Jidoka.AgentView.apply_event(view, event)

      @doc false
      @spec run(Jidoka.AgentView.t(), String.t(), keyword()) :: Jidoka.AgentView.t()
      def run(view, message, opts \\ []),
        do: Jidoka.AgentView.run(__MODULE__, view, message, opts)

      @doc false
      @spec visible_messages(Jidoka.AgentView.t()) :: [map()]
      def visible_messages(view), do: Jidoka.AgentView.visible_messages(view)

      @doc false
      @spec lifecycle_hooks() :: [atom()]
      def lifecycle_hooks, do: Jidoka.AgentView.lifecycle_hooks()

      @doc false
      @spec ui_hooks() :: [atom()]
      def ui_hooks, do: lifecycle_hooks()

      @doc false
      @spec request_id() :: String.t()
      def request_id, do: Jidoka.AgentView.request_id()

      @doc false
      @spec active_request_id(Jidoka.AgentView.t()) :: String.t() | nil
      def active_request_id(view), do: Jidoka.AgentView.active_request_id(view)

      defoverridable prepare: 1,
                     agent_module: 1,
                     conversation_id: 1,
                     agent_id: 1,
                     runtime_context: 1
    end
  end

  @doc "Returns the Zoi schema for AgentView."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds an AgentView struct from attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ %{}), do: Schema.parse(@schema, attrs)

  @doc "Builds an AgentView struct from attributes and raises on invalid input."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs \\ %{}), do: Schema.parse!(@schema, attrs, "agent view")

  @doc """
  Builds the initial projection for a view module and input.
  """
  @spec initial(module(), input(), keyword()) :: {:ok, t()} | {:error, term()}
  def initial(view_module, input \\ %{}, opts \\ [])
      when is_atom(view_module) and is_list(opts) do
    with :ok <- view_module.prepare(input) do
      agent = view_module.agent_module(input)

      new(
        agent_id: view_module.agent_id(input),
        conversation_id: view_module.conversation_id(input),
        runtime_context: view_module.runtime_context(input),
        metadata:
          %{
            view_module: inspect(view_module),
            agent_module: inspect(agent)
          }
          |> maybe_put_agent_projection(agent, opts)
      )
    end
  end

  @doc """
  Applies optimistic user-message state before an agent turn starts.
  """
  @spec before_turn(t(), String.t()) :: t()
  def before_turn(%__MODULE__{} = view, message) when is_binary(message) do
    before_turn(view, message, request_id())
  end

  @doc "Applies optimistic state for a known request before an agent turn starts."
  @spec before_turn(t(), String.t(), String.t()) :: t()
  def before_turn(%__MODULE__{} = view, message, request_id)
      when is_binary(message) and is_binary(request_id) do
    case String.trim(message) do
      "" ->
        view

      content ->
        view = activate_request(view, request_id)

        %{
          view
          | visible_messages: view.visible_messages ++ [user_message(content, pending?: true)],
            streaming_message: nil,
            status: :running,
            error: nil,
            error_text: nil,
            outcome: nil
        }
    end
  end

  @doc "Marks a request as the only request that can update the view."
  @spec activate_request(t(), String.t()) :: t()
  def activate_request(%__MODULE__{} = view, request_id)
      when is_binary(request_id) and byte_size(request_id) > 0 do
    %{
      view
      | streaming_message: nil,
        status: :running,
        error: nil,
        error_text: nil,
        outcome: nil,
        metadata:
          view.metadata
          |> Map.put(:active_request_id, request_id)
          |> Map.put(:request_lifecycle, :running)
          |> Map.put(:request_terminal_event, nil)
    }
  end

  @doc """
  Runs one turn for a view module and maps the runtime result back into view data.
  """
  @spec run(module(), t(), String.t(), keyword()) :: t()
  def run(view_module, %__MODULE__{} = view, message, opts \\ [])
      when is_atom(view_module) and is_binary(message) and is_list(opts) do
    case String.trim(message) do
      "" ->
        view

      _content ->
        request_id = request_id_from_opts(opts)
        running = before_turn(view, message, request_id)
        opts = Keyword.put(opts, :request_id, request_id)
        result = Runner.run_turn(view_module, running, message, opts)
        after_turn(running, result, request_id)
    end
  end

  @doc """
  Applies a Jidoka runtime result to view data.
  """
  @spec after_turn(
          t(),
          {:ok, Turn.Result.t()} | {:hibernate, Jidoka.Snapshot.t()} | {:error, term()}
        ) :: t()
  def after_turn(%__MODULE__{} = view, result) do
    case active_request_id(view) do
      request_id when is_binary(request_id) -> after_turn(view, result, request_id)
      nil -> view
    end
  end

  @doc "Applies a runtime result only when it belongs to the active request."
  @spec after_turn(
          t(),
          {:ok, Turn.Result.t()} | {:hibernate, Jidoka.Snapshot.t()} | {:error, term()},
          String.t()
        ) :: t()
  def after_turn(%__MODULE__{} = view, result, request_id) when is_binary(request_id) do
    if active_result?(view, request_id, result) do
      view
      |> apply_turn_result(result)
      |> settle_request(request_id)
    else
      view
    end
  end

  defp apply_turn_result(%__MODULE__{} = view, {:ok, %Turn.Result{} = result}) do
    %{
      view
      | visible_messages: commit_pending(view.visible_messages) ++ [assistant_message(result.content)],
        streaming_message: nil,
        events: Events.append_operation_events(view.events, result),
        status: :idle,
        error: nil,
        error_text: nil,
        outcome: {:ok, result},
        metadata:
          view.metadata
          |> Map.put(:agent_state, result.agent_state)
          |> Map.put(:last_result, Projection.project(result))
    }
  end

  defp apply_turn_result(%__MODULE__{} = view, {:hibernate, snapshot}) do
    %{
      view
      | visible_messages: commit_pending(view.visible_messages),
        streaming_message: nil,
        status: :interrupted,
        error: nil,
        error_text: "Agent hibernated for review.",
        outcome: {:hibernate, snapshot},
        metadata: Map.put(view.metadata, :last_snapshot, Projection.project(snapshot))
    }
  end

  defp apply_turn_result(%__MODULE__{} = view, {:error, reason}) do
    %{
      view
      | visible_messages: commit_pending(view.visible_messages),
        streaming_message: nil,
        status: :error,
        error: reason,
        error_text: Error.format(reason),
        outcome: {:error, reason}
    }
  end

  @doc """
  Applies a streamed Jidoka runtime event to view data.

  Content deltas update `streaming_message`; non-delta events are appended to
  `events` as compact debug projections.
  """
  @spec apply_event(t(), Event.t() | map()) :: t()
  def apply_event(%__MODULE__{} = view, event), do: Events.apply_event(view, event)

  @doc "Returns visible messages for a view."
  @spec visible_messages(t()) :: [map()]
  def visible_messages(%__MODULE__{} = view), do: Events.visible_messages(view)

  @doc "Returns lifecycle hook names supported by the AgentView contract."
  @spec lifecycle_hooks() :: [atom()]
  def lifecycle_hooks, do: [:before_turn, :after_turn, :snapshot]

  @doc "Generates a request id suitable for UI-initiated turns."
  @spec request_id() :: String.t()
  def request_id, do: Jidoka.Id.random("agent_view")

  @doc "Returns the request that can still update the view."
  @spec active_request_id(t()) :: String.t() | nil
  def active_request_id(%__MODULE__{metadata: metadata}) do
    case Map.get(metadata, :active_request_id) do
      request_id when is_binary(request_id) -> request_id
      _request_id -> nil
    end
  end

  @doc "Derives a conversation id from keyword, atom-key map, or string-key map input."
  @spec default_conversation_id(term()) :: String.t()
  def default_conversation_id(input) do
    input
    |> input_value(:conversation_id)
    |> normalize_id("default")
  end

  @doc "Derives a runtime agent id from an agent module and conversation id."
  @spec default_agent_id(term(), String.t()) :: String.t()
  def default_agent_id(agent, conversation_id) when is_binary(conversation_id) do
    base =
      cond do
        loaded_agent_module?(agent) and function_exported?(agent, :spec, 0) ->
          agent.spec().id

        loaded_agent_module?(agent) and function_exported?(agent, :id, 0) ->
          apply(agent, :id, [])

        is_atom(agent) ->
          agent |> Module.split() |> List.last() |> Macro.underscore()

        true ->
          "agent"
      end

    "#{base}-#{conversation_id}"
  end

  @doc "Derives default runtime context from a conversation id."
  @spec default_runtime_context(term(), String.t()) :: map()
  def default_runtime_context(_input, conversation_id), do: %{session: conversation_id}

  @doc "Normalizes arbitrary text into a stable lower-snake id."
  @spec normalize_id(term(), String.t()) :: String.t()
  def normalize_id(value, default \\ "default")
  def normalize_id(nil, default), do: default

  def normalize_id(value, default) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> default
      id -> id
    end
  end

  defp maybe_put_agent_projection(metadata, agent, opts) do
    if Keyword.get(opts, :project_agent?, true) do
      Map.put(metadata, :agent, agent_projection(agent))
    else
      metadata
    end
  end

  defp agent_projection(agent) when is_atom(agent) do
    if loaded_agent_module?(agent) and function_exported?(agent, :spec, 0) do
      Projection.project(agent.spec())
    else
      %{module: inspect(agent)}
    end
  end

  defp agent_projection(agent), do: Projection.project(agent)

  defp user_message(content, opts) do
    %{
      id: message_id("user"),
      seq: -1,
      role: :user,
      content: content,
      pending?: Keyword.get(opts, :pending?, false)
    }
  end

  defp assistant_message(content) do
    %{
      id: message_id("assistant"),
      seq: -1,
      role: :assistant,
      content: content
    }
  end

  defp message_id(prefix), do: Jidoka.Id.random(prefix)

  defp commit_pending(messages) do
    Enum.map(messages, &Map.put(&1, :pending?, false))
  end

  defp input_value(input, key) when is_list(input) and is_atom(key), do: Keyword.get(input, key)

  defp input_value(%{} = input, key) when is_atom(key) do
    Map.get(input, key, Map.get(input, Atom.to_string(key)))
  end

  defp input_value(_input, _key), do: nil

  defp active_result?(%__MODULE__{} = view, request_id, result) do
    active_request_id(view) == request_id and result_matches_lifecycle?(view.metadata, result)
  end

  defp result_matches_lifecycle?(%{request_lifecycle: :running}, _result), do: true

  defp result_matches_lifecycle?(%{request_lifecycle: :terminal} = metadata, result) do
    Map.get(metadata, :request_terminal_event) == result_terminal_event(result)
  end

  defp result_matches_lifecycle?(_metadata, _result), do: false

  defp result_terminal_event({:ok, %Turn.Result{}}), do: :turn_finished
  defp result_terminal_event({:hibernate, _snapshot}), do: :turn_hibernated
  defp result_terminal_event({:error, _reason}), do: :turn_failed
  defp result_terminal_event(_result), do: nil

  defp settle_request(%__MODULE__{} = view, request_id) do
    %{
      view
      | metadata:
          view.metadata
          |> Map.put(:active_request_id, nil)
          |> Map.put(:last_request_id, request_id)
          |> Map.put(:request_lifecycle, :settled)
          |> Map.put(:request_terminal_event, nil)
    }
  end

  defp request_id_from_opts(opts) do
    case Keyword.get(opts, :request_id) do
      request_id when is_binary(request_id) and byte_size(request_id) > 0 -> request_id
      _request_id -> request_id()
    end
  end

  defp loaded_agent_module?(agent), do: is_atom(agent) and Code.ensure_loaded?(agent)
end
