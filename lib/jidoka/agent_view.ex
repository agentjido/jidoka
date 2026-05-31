defmodule Jidoka.AgentView do
  @moduledoc """
  Surface-neutral UI projection contract for a Jidoka agent.

  `AgentView` is not a Phoenix view and does not render HTML. It is a small
  application-facing projection that LiveView, CLI examples, channels, tests, or
  jobs can use to keep UI state separate from the durable agent runtime.

  The struct is projection-only. It stores no pid, transcript persistence,
  provider client, process state, or adapter data.
  """

  alias Jidoka.Schema
  alias Jidoka.Event
  alias Jidoka.Stream, as: EventStream
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

  @callback prepare(input()) :: :ok | {:error, term()}
  @callback agent_module(input()) :: module() | Jidoka.Agent.Spec.t() | Jidoka.Turn.Plan.t()
  @callback conversation_id(input()) :: String.t()
  @callback agent_id(input()) :: String.t()
  @callback runtime_context(input()) :: map()

  @doc false
  defmacro __using__(opts \\ []) do
    agent = Keyword.get(opts, :agent)

    quote bind_quoted: [agent: agent] do
      @behaviour Jidoka.AgentView

      @jidoka_agent_view_agent agent

      @impl Jidoka.AgentView
      def prepare(_input), do: :ok

      @impl Jidoka.AgentView
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
      def conversation_id(input), do: Jidoka.AgentView.default_conversation_id(input)

      @impl Jidoka.AgentView
      def agent_id(input),
        do: Jidoka.AgentView.default_agent_id(agent_module(input), conversation_id(input))

      @impl Jidoka.AgentView
      def runtime_context(input),
        do: Jidoka.AgentView.default_runtime_context(input, conversation_id(input))

      @doc false
      def initial(input \\ %{}, opts \\ []), do: Jidoka.AgentView.initial(__MODULE__, input, opts)

      @doc false
      def before_turn(view, message), do: Jidoka.AgentView.before_turn(view, message)

      @doc false
      def after_turn(view, result), do: Jidoka.AgentView.after_turn(view, result)

      @doc false
      def apply_event(view, event), do: Jidoka.AgentView.apply_event(view, event)

      @doc false
      def run(view, message, opts \\ []),
        do: Jidoka.AgentView.run(__MODULE__, view, message, opts)

      @doc false
      def visible_messages(view), do: Jidoka.AgentView.visible_messages(view)

      @doc false
      def lifecycle_hooks, do: Jidoka.AgentView.lifecycle_hooks()

      @doc false
      def ui_hooks, do: lifecycle_hooks()

      @doc false
      def request_id, do: Jidoka.AgentView.request_id()

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
    case String.trim(message) do
      "" ->
        %{view | status: :idle}

      content ->
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

  @doc """
  Runs one turn for a view module and maps the runtime result back into view data.
  """
  @spec run(module(), t(), String.t(), keyword()) :: t()
  def run(view_module, %__MODULE__{} = view, message, opts \\ [])
      when is_atom(view_module) and is_binary(message) and is_list(opts) do
    running = before_turn(view, message)
    result = run_agent_turn(view_module, running, message, opts)
    after_turn(running, result)
  end

  @doc """
  Applies a Jidoka runtime result to view data.
  """
  @spec after_turn(t(), Jidoka.run_result()) :: t()
  def after_turn(%__MODULE__{} = view, {:ok, %Turn.Result{} = result}) do
    %{
      view
      | visible_messages:
          commit_pending(view.visible_messages) ++ [assistant_message(result.content)],
        streaming_message: nil,
        events: append_operation_events(view.events, result),
        status: :idle,
        error: nil,
        error_text: nil,
        outcome: {:ok, result},
        metadata:
          view.metadata
          |> Map.put(:agent_state, result.agent_state)
          |> Map.put(:last_result, Jidoka.projection(result))
    }
  end

  def after_turn(%__MODULE__{} = view, {:hibernate, snapshot}) do
    %{
      view
      | visible_messages: commit_pending(view.visible_messages),
        streaming_message: nil,
        status: :interrupted,
        error: nil,
        error_text: "Agent hibernated for review.",
        outcome: {:hibernate, snapshot},
        metadata: Map.put(view.metadata, :last_snapshot, Jidoka.projection(snapshot))
    }
  end

  def after_turn(%__MODULE__{} = view, {:error, reason}) do
    %{
      view
      | visible_messages: commit_pending(view.visible_messages),
        streaming_message: nil,
        status: :error,
        error: reason,
        error_text: Jidoka.format_error(reason),
        outcome: {:error, reason}
    }
  end

  @doc """
  Applies a streamed Jidoka runtime event to view data.

  Content deltas update `streaming_message`; non-delta events are appended to
  `events` as compact debug projections.
  """
  @spec apply_event(t(), Event.t() | map()) :: t()
  def apply_event(%__MODULE__{} = view, %Event{} = event) do
    view
    |> apply_stream_delta(event)
    |> append_runtime_event(event)
  end

  def apply_event(%__MODULE__{} = view, _event), do: view

  @doc "Returns visible messages for a view."
  @spec visible_messages(t()) :: [map()]
  def visible_messages(%__MODULE__{streaming_message: nil} = view), do: view.visible_messages

  def visible_messages(%__MODULE__{} = view),
    do: view.visible_messages ++ [view.streaming_message]

  @doc "Returns lifecycle hook names supported by the AgentView contract."
  @spec lifecycle_hooks() :: [atom()]
  def lifecycle_hooks, do: [:before_turn, :after_turn, :snapshot]

  @doc "Generates a request id suitable for UI-initiated turns."
  @spec request_id() :: String.t()
  def request_id, do: Jidoka.Id.random("agent_view")

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

  defp run_agent_turn(view_module, %__MODULE__{} = view, message, opts) do
    input = %{conversation_id: view.conversation_id, runtime_context: view.runtime_context}
    agent = view_module.agent_module(input)

    opts =
      opts
      |> Keyword.put_new(:request_id, request_id())
      |> Keyword.put_new(:context, view.runtime_context)

    request_input =
      %{input: message, context: view.runtime_context}
      |> maybe_put_agent_state(Map.get(view.metadata, :agent_state))

    cond do
      loaded_agent_module?(agent) and function_exported?(agent, :run_turn, 2) ->
        apply(agent, :run_turn, [request_input, opts])

      true ->
        Jidoka.run_turn(agent, request_input, opts)
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
    cond do
      loaded_agent_module?(agent) and function_exported?(agent, :spec, 0) ->
        Jidoka.projection(agent.spec())

      true ->
        %{module: inspect(agent)}
    end
  end

  defp agent_projection(agent), do: Jidoka.projection(agent)

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

  defp append_operation_events(events, %Turn.Result{} = result) do
    existing_ids = MapSet.new(events, & &1.id)

    result
    |> operation_events()
    |> Enum.reject(&MapSet.member?(existing_ids, &1.id))
    |> then(&(events ++ &1))
  end

  defp apply_stream_delta(%__MODULE__{} = view, %Event{} = event) do
    cond do
      is_binary(EventStream.text_delta(event)) ->
        update_streaming_message(view, event, :content, EventStream.text_delta(event))

      is_binary(EventStream.thinking_delta(event)) ->
        update_streaming_message(view, event, :thinking, EventStream.thinking_delta(event))

      true ->
        view
    end
  end

  defp update_streaming_message(%__MODULE__{} = view, %Event{} = event, :content, delta) do
    message = streaming_message(view.streaming_message, event)
    content = Map.get(message, :content, "") <> delta

    %{view | streaming_message: Map.put(message, :content, content), status: :running}
  end

  defp update_streaming_message(%__MODULE__{} = view, %Event{} = event, :thinking, delta) do
    message = streaming_message(view.streaming_message, event)
    thinking = Map.get(message, :thinking, "") <> delta

    message =
      message
      |> Map.put(:thinking, thinking)
      |> Map.update(:content, "Thinking...", fn
        "" -> "Thinking..."
        content -> content
      end)

    %{view | streaming_message: message, status: :running}
  end

  defp streaming_message(nil, %Event{} = event) do
    request_id = event.request_id || request_id()

    %{
      id: "streaming-" <> request_id,
      seq: -1,
      role: :assistant,
      content: "",
      request_id: request_id,
      streaming?: true
    }
  end

  defp streaming_message(%{} = message, _event), do: message

  defp append_runtime_event(%__MODULE__{} = view, %Event{event: :llm_delta}), do: view

  defp append_runtime_event(%__MODULE__{} = view, %Event{} = event) do
    projected = runtime_event(event)

    if Enum.any?(view.events, &(&1.id == projected.id)) do
      view
    else
      %{view | events: view.events ++ [projected]}
    end
  end

  defp runtime_event(%Event{} = event) do
    %{
      id: runtime_event_id(event),
      kind: event.event,
      label: event_label(event),
      payload: Event.to_map(event),
      refs: %{
        operation: event.operation,
        effect_id: event.effect_id,
        request_id: event.request_id
      }
    }
  end

  defp runtime_event_id(%Event{} = event) do
    [
      "event",
      event.request_id || "turn",
      event.seq,
      event.event,
      event.effect_id
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("-", &to_string/1)
  end

  defp event_label(%Event{operation: operation}) when is_binary(operation) do
    "#{humanize_event(:operation)}: #{operation}"
  end

  defp event_label(%Event{event: event}), do: humanize_event(event)

  defp humanize_event(event) do
    event
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp operation_events(%Turn.Result{} = result) do
    Enum.map(result.agent_state.operation_results, fn operation_result ->
      projection = Jidoka.projection(operation_result)

      %{
        id: operation_result.effect_id || message_id("operation"),
        kind: :operation_result,
        label: "tool result: #{operation_result.operation}",
        payload: projection,
        refs: %{operation: operation_result.operation}
      }
    end)
  end

  defp input_value(input, key) when is_list(input) and is_atom(key), do: Keyword.get(input, key)

  defp input_value(%{} = input, key) when is_atom(key) do
    Map.get(input, key, Map.get(input, Atom.to_string(key)))
  end

  defp input_value(_input, _key), do: nil

  defp maybe_put_agent_state(request_input, nil), do: request_input

  defp maybe_put_agent_state(request_input, agent_state),
    do: Map.put(request_input, :agent_state, agent_state)

  defp loaded_agent_module?(agent), do: is_atom(agent) and Code.ensure_loaded?(agent)
end
