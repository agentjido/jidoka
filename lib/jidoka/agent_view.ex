defmodule Jidoka.AgentView do
  @moduledoc """
  Least-common-denominator view contract for a Jidoka agent.

  An `AgentView` is not a Phoenix view and does not render UI. It is the
  application-facing adapter between an agent runtime and any interaction
  surface: LiveView, controllers, CLI sessions, tests, channels, or jobs.

  `Jidoka.Agent.View` remains the low-level projection from `Jido.Thread` and
  strategy state. `Jidoka.AgentView` adds the app-specific pieces that every
  surface needs:

  - choosing the agent module
  - deriving a stable conversation id
  - deriving a stable runtime agent id
  - building runtime context
  - starting or reusing the agent
  - exposing visible messages, streaming drafts, LLM context, and debug events
  - mapping runtime results into a surface-neutral view state

  In Phoenix applications, keep process ownership outside the view layer. Store
  the `%Jidoka.Session{}` or runtime agent reference, the latest `%AgentView{}`
  projection, and any in-flight run handle in socket assigns; let the running
  agent process and `Jido.Thread` remain the canonical state. Refresh this
  projection from the runtime after turns complete instead of treating it as a
  transcript store or persistence layer.
  """

  alias Jido.AI.Request
  alias Jidoka.AgentView.{Defaults, Projection, Run, Start, TurnState}

  @type input :: term()
  @type status :: :idle | :running | :error | :interrupted | :handoff

  @type t :: %__MODULE__{
          agent_id: String.t(),
          conversation_id: String.t(),
          runtime_context: map(),
          visible_messages: [map()],
          streaming_message: map() | nil,
          llm_context: [map()],
          events: [map()],
          status: status(),
          error: term() | nil,
          error_text: String.t() | nil,
          outcome: term() | nil,
          metadata: map()
        }

  defstruct agent_id: "agent-default",
            conversation_id: "default",
            runtime_context: %{},
            visible_messages: [],
            streaming_message: nil,
            llm_context: [],
            events: [],
            status: :idle,
            error: nil,
            error_text: nil,
            outcome: nil,
            metadata: %{}

  @callback prepare(input()) :: :ok | {:error, term()}
  @callback agent_module(input()) :: module() | Jidoka.ImportedAgent.t()
  @callback conversation_id(input()) :: String.t()
  @callback agent_id(input()) :: String.t()
  @callback runtime_context(input()) :: map()

  @doc false
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts \\ []) do
    agent = Keyword.get(opts, :agent)

    quote bind_quoted: [agent: agent] do
      @behaviour Jidoka.AgentView

      @jidoka_agent_view_agent agent

      @doc false
      @impl Jidoka.AgentView
      @spec prepare(Jidoka.AgentView.input()) :: :ok | {:error, term()}
      def prepare(_input), do: :ok

      @doc false
      @impl Jidoka.AgentView
      @spec agent_module(Jidoka.AgentView.input()) :: module() | Jidoka.ImportedAgent.t()
      def agent_module(input) do
        case @jidoka_agent_view_agent do
          nil ->
            case Jidoka.AgentView.default_agent_module(input) do
              nil ->
                raise ArgumentError,
                      "#{inspect(__MODULE__)} must pass `agent:` to `use Jidoka.AgentView`, pass a %Jidoka.Session{} input, or override agent_module/1"

              agent ->
                agent
            end

          module ->
            module
        end
      end

      @doc false
      @impl Jidoka.AgentView
      @spec conversation_id(Jidoka.AgentView.input()) :: String.t()
      def conversation_id(input), do: Jidoka.AgentView.default_conversation_id(input)

      @doc false
      @impl Jidoka.AgentView
      @spec agent_id(Jidoka.AgentView.input()) :: String.t()
      def agent_id(%Jidoka.Session{} = session), do: session.agent_id

      def agent_id(input), do: Jidoka.AgentView.default_agent_id(agent_module(input), conversation_id(input))

      @doc false
      @impl Jidoka.AgentView
      @spec runtime_context(Jidoka.AgentView.input()) :: map()
      def runtime_context(%Jidoka.Session{} = session), do: session.context

      def runtime_context(input), do: Jidoka.AgentView.default_runtime_context(input, conversation_id(input))

      @doc false
      @spec start_agent(Jidoka.AgentView.input()) :: {:ok, pid()} | {:error, term()}
      def start_agent(input), do: Jidoka.AgentView.start_agent(__MODULE__, input)

      @doc false
      @spec snapshot(Request.server(), Jidoka.AgentView.input(), keyword()) ::
              {:ok, Jidoka.AgentView.t()} | {:error, term()}
      def snapshot(agent_ref, input, opts \\ []), do: Jidoka.AgentView.snapshot(__MODULE__, agent_ref, input, opts)

      @doc false
      @spec before_turn(Jidoka.AgentView.t(), String.t()) :: Jidoka.AgentView.t()
      def before_turn(view, message), do: Jidoka.AgentView.before_turn(view, message)

      @doc false
      @spec start_turn(pid(), String.t(), Jidoka.AgentView.input(), keyword()) ::
              {:ok, Jidoka.AgentView.Run.t()} | {:error, term()}
      def start_turn(pid, message, input, opts \\ []) do
        Jidoka.AgentView.start_turn(__MODULE__, pid, message, input, opts)
      end

      @doc false
      @spec await_turn(Jidoka.AgentView.Run.t(), keyword()) ::
              {:ok, term()}
              | {:interrupt, Jidoka.Interrupt.t()}
              | {:handoff, Jidoka.Handoff.t()}
              | {:error, term()}
      def await_turn(run, opts \\ []) do
        Jidoka.AgentView.await_turn(__MODULE__, run, opts)
      end

      @doc false
      @spec refresh_turn(Jidoka.AgentView.Run.t(), Jidoka.AgentView.t()) ::
              {:ok, Jidoka.AgentView.t()} | {:error, term()}
      def refresh_turn(run, current_view) do
        Jidoka.AgentView.refresh_turn(__MODULE__, run, current_view)
      end

      @doc false
      @spec after_turn(Jidoka.AgentView.Run.t(), term()) :: {:ok, Jidoka.AgentView.t()} | {:error, term()}
      def after_turn(run, result), do: Jidoka.AgentView.after_turn(__MODULE__, run, result)

      @doc false
      @spec before_submit(Jidoka.AgentView.t(), String.t()) :: Jidoka.AgentView.t()
      def before_submit(view, message), do: before_turn(view, message)

      @doc false
      @spec start_message(pid(), String.t(), Jidoka.AgentView.input(), keyword()) ::
              {:ok, Jidoka.AgentView.Run.t()} | {:error, term()}
      def start_message(pid, message, input, opts \\ []), do: start_turn(pid, message, input, opts)

      @doc false
      @spec await_message(pid(), Jidoka.AgentView.Run.t() | Request.Handle.t(), keyword()) ::
              {:ok, term()}
              | {:interrupt, Jidoka.Interrupt.t()}
              | {:handoff, Jidoka.Handoff.t()}
              | {:error, term()}
      def await_message(pid, run_or_request, opts \\ []) do
        Jidoka.AgentView.await_message(__MODULE__, pid, run_or_request, opts)
      end

      @doc false
      @spec refresh_running(pid(), Jidoka.AgentView.input(), Jidoka.AgentView.t()) ::
              {:ok, Jidoka.AgentView.t()} | {:error, term()}
      def refresh_running(pid, input, current_view) do
        Jidoka.AgentView.refresh_running(__MODULE__, pid, input, current_view)
      end

      @doc false
      @spec after_result(pid(), Jidoka.AgentView.input(), term()) :: {:ok, Jidoka.AgentView.t()} | {:error, term()}
      def after_result(pid, input, result), do: Jidoka.AgentView.after_result(__MODULE__, pid, input, result)

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

      defoverridable prepare: 1,
                     agent_module: 1,
                     conversation_id: 1,
                     agent_id: 1,
                     runtime_context: 1
    end
  end

  @doc """
  Builds an AgentView struct from attributes.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs \\ %{}) do
    attrs =
      if Keyword.keyword?(attrs) do
        Map.new(attrs)
      else
        attrs
      end

    struct(__MODULE__, attrs)
  end

  @doc """
  Starts or reuses the agent for `view_module` and `input`.
  """
  @spec start_agent(module(), input()) :: {:ok, pid()} | {:error, term()}
  def start_agent(view_module, input) when is_atom(view_module) do
    Start.start_agent(view_module, input)
  end

  @doc """
  Projects the running agent into a surface-neutral AgentView struct.
  """
  @spec snapshot(module(), Request.server(), input(), keyword()) :: {:ok, t()} | {:error, term()}
  def snapshot(view_module, agent_ref, input, opts \\ []) when is_atom(view_module) and is_list(opts) do
    with {:ok, attrs} <- Projection.snapshot_attrs(view_module, agent_ref, input, opts) do
      {:ok, new(attrs)}
    end
  end

  @doc """
  Applies optimistic user-message state before an agent turn starts.
  """
  @spec before_turn(t(), String.t()) :: t()
  def before_turn(%__MODULE__{} = view, message) when is_binary(message) do
    TurnState.before_turn(view, message)
  end

  @doc """
  Compatibility alias for `before_turn/2`.
  """
  @spec before_submit(t(), String.t()) :: t()
  def before_submit(%__MODULE__{} = view, message) when is_binary(message), do: before_turn(view, message)

  @doc """
  Starts a non-blocking agent turn.
  """
  @spec start_turn(module(), pid(), String.t(), input(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def start_turn(view_module, pid, message, input, opts \\ [])
      when is_atom(view_module) and is_pid(pid) and is_binary(message) and is_list(opts) do
    case String.trim(message) do
      "" ->
        {:error, Jidoka.Error.validation_error("Message must not be empty.", field: :message)}

      content ->
        with :ok <- Start.prepare_view(view_module, input) do
          chat_opts =
            opts
            |> Keyword.put(:conversation, view_module.conversation_id(input))
            |> Keyword.put(:context, view_module.runtime_context(input))
            |> Keyword.put_new_lazy(:request_id, &request_id/0)
            |> Keyword.put_new(:timeout, 30_000)

          with {:ok, request} <- Jidoka.start_chat_request(pid, content, chat_opts) do
            {:ok, TurnState.build_run(view_module, request, input, chat_opts)}
          end
        end
    end
  end

  @doc """
  Compatibility alias for `start_turn/5`.
  """
  @spec start_message(module(), pid(), String.t(), input(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def start_message(view_module, pid, message, input, opts \\ []),
    do: start_turn(view_module, pid, message, input, opts)

  @doc """
  Awaits an async agent turn and returns the normal public Jidoka chat result.
  """
  @spec await_turn(module(), Run.t(), keyword()) ::
          {:ok, term()}
          | {:interrupt, Jidoka.Interrupt.t()}
          | {:handoff, Jidoka.Handoff.t()}
          | {:error, term()}
  def await_turn(_view_module, %Run{request: request}, opts \\ []) when is_list(opts) do
    Jidoka.await_chat_request(request, timeout: Keyword.get(opts, :timeout, 30_000))
  end

  @doc """
  Compatibility alias for `await_turn/3`.
  """
  @spec await_message(module(), pid(), Run.t() | Request.Handle.t(), keyword()) ::
          {:ok, term()}
          | {:interrupt, Jidoka.Interrupt.t()}
          | {:handoff, Jidoka.Handoff.t()}
          | {:error, term()}
  def await_message(view_module, _pid, %Run{} = run, opts), do: await_turn(view_module, run, opts)

  def await_message(_view_module, _pid, %Request.Handle{} = request, opts) do
    Jidoka.await_chat_request(request, timeout: Keyword.get(opts, :timeout, 30_000))
  end

  @doc """
  Refreshes a running turn while preserving optimistic messages until the thread catches up.
  """
  @spec refresh_turn(module(), Run.t(), t()) :: {:ok, t()} | {:error, term()}
  def refresh_turn(view_module, %Run{} = run, %__MODULE__{} = current_view) when is_atom(view_module) do
    with {:ok, view} <- snapshot(view_module, run.agent_ref, run.input, request_id: run.request_id) do
      {:ok,
       %{
         view
         | visible_messages: TurnState.running_visible_messages(current_view.visible_messages, view.visible_messages),
           status: :running,
           error: nil,
           error_text: nil
       }}
    end
  end

  @doc """
  Compatibility refresh helper for callers that only have a pid.
  """
  @spec refresh_running(module(), pid(), input(), t()) :: {:ok, t()} | {:error, term()}
  def refresh_running(view_module, pid, input, %__MODULE__{} = current_view)
      when is_atom(view_module) and is_pid(pid) do
    refresh_turn(
      view_module,
      TurnState.build_run(view_module, Request.Handle.new("__compat__", pid, ""), input, []),
      current_view
    )
  end

  @doc """
  Re-projects the agent and applies the final public chat result to view state.
  """
  @spec after_turn(module(), Run.t(), term()) :: {:ok, t()} | {:error, term()}
  def after_turn(view_module, %Run{} = run, result) when is_atom(view_module) do
    with {:ok, view} <- snapshot(view_module, run.agent_ref, run.input, request_id: run.request_id) do
      {:ok, TurnState.apply_result(view, result)}
    end
  end

  @doc """
  Compatibility result helper for callers that only have a pid.
  """
  @spec after_result(module(), pid(), input(), term()) :: {:ok, t()} | {:error, term()}
  def after_result(view_module, pid, input, result) when is_atom(view_module) and is_pid(pid) do
    after_turn(
      view_module,
      TurnState.build_run(view_module, Request.Handle.new("__compat__", pid, ""), input, []),
      result
    )
  end

  @doc """
  Returns visible transcript messages plus the in-flight streaming draft, if any.
  """
  @spec visible_messages(t() | map()) :: [map()]
  def visible_messages(view), do: Projection.visible_messages(view)

  @doc """
  Returns the standard AgentView lifecycle hook names.
  """
  @spec lifecycle_hooks() :: [atom()]
  def lifecycle_hooks, do: [:before_turn, :after_turn, :snapshot]

  @doc """
  Compatibility alias for `lifecycle_hooks/0`.
  """
  @spec ui_hooks() :: [atom()]
  def ui_hooks, do: lifecycle_hooks()

  @doc """
  Generates a request id suitable for view-owned async chat requests.
  """
  @spec request_id() :: String.t()
  def request_id do
    "agent-view-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  @doc """
  Default agent module derivation for session inputs.
  """
  @spec default_agent_module(input()) :: Jidoka.Session.agent() | nil
  def default_agent_module(%Jidoka.Session{agent: agent}), do: agent
  def default_agent_module(_input), do: nil

  @doc """
  Default conversation id derivation for map, keyword, or arbitrary input.
  """
  @spec default_conversation_id(input()) :: String.t()
  def default_conversation_id(input), do: Defaults.conversation_id(input)

  @doc """
  Default runtime agent id derivation.
  """
  @spec default_agent_id(module(), String.t()) :: String.t()
  def default_agent_id(agent, conversation_id) when is_atom(agent) and is_binary(conversation_id) do
    Defaults.agent_id(agent, conversation_id)
  end

  @doc """
  Default runtime context for an agent view.
  """
  @spec default_runtime_context(input(), String.t()) :: map()
  def default_runtime_context(input, conversation_id), do: Defaults.runtime_context(input, conversation_id)

  @doc """
  Normalizes user/application ids into stable lower snake case.
  """
  @spec normalize_id(term(), String.t()) :: String.t()
  def normalize_id(value, default \\ "default")

  def normalize_id(value, default), do: Defaults.normalize_id(value, default)
end
