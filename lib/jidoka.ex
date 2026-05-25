defmodule Jidoka do
  @moduledoc """
  Minimal runtime facade for starting and discovering Jidoka agents.
  """

  alias Jidoka.{ImportedAgent, Session}

  @doc """
  Returns Jidoka-owned model aliases from application config.

  These aliases are defined under `config :jidoka, :model_aliases`.
  """
  @spec model_aliases() :: %{optional(atom()) => term()}
  defdelegate model_aliases(), to: Jidoka.Model

  @doc """
  Normalizes a model input using Jidoka aliases first, then Jido.AI.
  """
  @spec model(Jido.AI.model_input()) :: ReqLLM.model_input()
  defdelegate model(model), to: Jidoka.Model

  @doc """
  Starts an agent under the shared `Jidoka.Runtime` instance.
  """
  def start_agent(agent, opts \\ [])

  @spec start_agent(ImportedAgent.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_agent(%ImportedAgent{} = agent, opts), do: ImportedAgent.start_link(agent, opts)

  @spec start_agent(module() | struct(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_agent(agent, opts), do: Jidoka.Runtime.start_agent(agent, opts)

  @doc """
  Stops an agent by PID or registered ID.
  """
  @spec stop_agent(pid() | String.t(), keyword()) :: :ok | {:error, :not_found}
  def stop_agent(pid_or_id, opts \\ []), do: Jidoka.Runtime.stop_agent(pid_or_id, opts)

  @doc """
  Looks up a running agent by ID.
  """
  @spec whereis(String.t(), keyword()) :: pid() | nil
  def whereis(id, opts \\ []), do: Jidoka.Runtime.whereis(id, opts)

  @doc """
  Lists all running agents.
  """
  @spec list_agents(keyword()) :: [{String.t(), pid()}]
  def list_agents(opts \\ []), do: Jidoka.Runtime.list_agents(opts)

  @doc """
  Imports a constrained Jidoka agent from a map, JSON string, or YAML string.

  This portability surface is experimental in the beta. It is intended for
  controlled interchange, fixtures, and registry-backed portability tests while
  the canonical Elixir DSL settles.

  Importing is constrained data loading, not arbitrary code loading. Raw module
  strings in specs are rejected. Any module-backed capability must be made
  available through an explicit host-provided registry.

  The imported format mirrors the beta DSL sections: `agent`, `defaults`,
  `capabilities`, and `lifecycle`.

  Imported tools and plugins must be resolved through the explicit
  `:available_tools`, `:available_subagents`, `:available_plugins`,
  `:available_hooks`, and
  `:available_guardrails` registries passed in `opts`.
  """
  @spec import_agent(map() | binary(), keyword()) :: {:ok, ImportedAgent.t()} | {:error, term()}
  def import_agent(source, opts \\ []), do: ImportedAgent.import(source, opts)

  @doc """
  Imports a constrained Jidoka agent and raises on failure.
  """
  @spec import_agent!(map() | binary(), keyword()) :: ImportedAgent.t()
  def import_agent!(source, opts \\ []) do
    case import_agent(source, opts) do
      {:ok, agent} -> agent
      {:error, reason} -> raise ArgumentError, message: ImportedAgent.format_error(reason)
    end
  end

  @doc """
  Imports a constrained Jidoka agent from a `.json`, `.yaml`, or `.yml` file.
  """
  @spec import_agent_file(Path.t(), keyword()) :: {:ok, ImportedAgent.t()} | {:error, term()}
  def import_agent_file(path, opts \\ []), do: ImportedAgent.import_file(path, opts)

  @doc """
  Imports a constrained Jidoka agent from a file and raises on failure.
  """
  @spec import_agent_file!(Path.t(), keyword()) :: ImportedAgent.t()
  def import_agent_file!(path, opts \\ []) do
    case import_agent_file(path, opts) do
      {:ok, agent} -> agent
      {:error, reason} -> raise ArgumentError, message: ImportedAgent.format_error(reason)
    end
  end

  @doc """
  Encodes an imported Jidoka agent as JSON or YAML.
  """
  @spec encode_agent(ImportedAgent.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def encode_agent(agent, opts \\ [])
  def encode_agent(%ImportedAgent{} = agent, opts), do: ImportedAgent.encode(agent, opts)

  @doc """
  Formats Jidoka error terms for humans.

  Use this helper when presenting Jidoka errors in CLIs, demos, logs, or tests.
  """
  @spec format_error(term()) :: String.t()
  def format_error(reason), do: Jidoka.Error.format(reason)

  @doc """
  Encodes an imported Jidoka agent as JSON or YAML and raises on failure.
  """
  @spec encode_agent!(ImportedAgent.t(), keyword()) :: binary()
  def encode_agent!(agent, opts \\ [])

  def encode_agent!(%ImportedAgent{} = agent, opts) do
    case encode_agent(agent, opts) do
      {:ok, encoded} -> encoded
      {:error, reason} -> raise ArgumentError, message: ImportedAgent.format_error(reason)
    end
  end

  @doc """
  Builds a pipe-friendly session descriptor for an agent and conversation id.

  This is a convenience wrapper around `Jidoka.Session.new!/1` for the common
  shape:

      MyApp.AssistantAgent
      |> Jidoka.session("user-123", context: %{actor: current_user})
      |> Jidoka.chat("Summarize this ticket.")
  """
  @spec session(Session.agent(), String.t() | atom(), keyword()) :: Session.t()
  def session(agent, id, opts \\ []) when is_list(opts) do
    opts
    |> Keyword.put(:agent, agent)
    |> Keyword.put(:id, id)
    |> Session.new!()
  end

  @doc """
  Sends a chat request to a running Jidoka agent and waits for the result.

  Accepts a Jidoka agent module, `%Jidoka.Session{}`, PID, server reference,
  or running Jidoka agent ID string. Module targets start or reuse the generated
  runtime agent under the module's public `id/0`. Use a PID or registered ID
  when your application owns the process explicitly; use a session when the turn
  belongs to a named conversation.

  Pass `stream: true` to return a `Jidoka.Chat.Stream` enumerable immediately
  instead of waiting for the final result.
  """
  @spec chat(Session.t() | pid() | atom() | {:via, module(), term()} | String.t(), String.t(), keyword()) ::
          {:ok, term()}
          | {:ok, Jidoka.Chat.Stream.t()}
          | {:error, term()}
          | {:interrupt, Jidoka.Interrupt.t()}
          | {:handoff, Jidoka.Handoff.t()}
  defdelegate chat(server_or_id, message, opts \\ []), to: Jidoka.Chat

  @doc """
  Starts a streaming chat request and returns an enumerable of runtime events.

  This is equivalent to `chat(target, message, stream: true)`, but makes the
  streaming shape explicit at the call site. Use `Jidoka.Chat.Stream.await/2`
  to wait for the normalized final result.
  """
  @spec chat_stream(Session.t() | pid() | atom() | {:via, module(), term()} | String.t(), String.t(), keyword()) ::
          {:ok, Jidoka.Chat.Stream.t()} | {:error, term()}
  defdelegate chat_stream(server_or_id, message, opts \\ []), to: Jidoka.Chat

  @doc false
  @spec start_chat_request(Session.t() | pid() | atom() | {:via, module(), term()} | String.t(), String.t(), keyword()) ::
          {:ok, Jido.AI.Request.Handle.t()} | {:error, term()}
  defdelegate start_chat_request(server_or_id, message, opts \\ []), to: Jidoka.Chat

  @doc false
  @spec await_chat_request(Jido.AI.Request.Handle.t(), keyword()) ::
          {:ok, term()} | {:error, term()} | {:interrupt, Jidoka.Interrupt.t()} | {:handoff, Jidoka.Handoff.t()}
  defdelegate await_chat_request(request, opts \\ []), to: Jidoka.Chat

  @doc """
  Registers a first-class Jidoka schedule.

  Agent schedules run through `Jidoka.chat/3`; workflow schedules run through
  `Jidoka.Workflow.run/3`. The default scheduler is in-memory and supervised by
  the Jidoka application.
  """
  @spec schedule(Jidoka.Schedule.target(), keyword()) :: {:ok, Jidoka.Schedule.t()} | {:error, term()}
  defdelegate schedule(target, opts), to: Jidoka.Schedule.Manager

  @doc """
  Convenience alias for registering an agent schedule.
  """
  @spec schedule_agent(Jidoka.Schedule.target(), keyword()) :: {:ok, Jidoka.Schedule.t()} | {:error, term()}
  def schedule_agent(target, opts) when is_list(opts), do: schedule(target, Keyword.put(opts, :kind, :agent))

  @doc """
  Registers a workflow schedule.
  """
  @spec schedule_workflow(module(), keyword()) :: {:ok, Jidoka.Schedule.t()} | {:error, term()}
  def schedule_workflow(workflow_module, opts) when is_atom(workflow_module) and is_list(opts) do
    schedule(workflow_module, Keyword.put(opts, :kind, :workflow))
  end

  @doc """
  Lists schedules registered with the Jidoka schedule manager.
  """
  @spec list_schedules(keyword()) :: {:ok, [Jidoka.Schedule.t()]} | {:error, term()}
  defdelegate list_schedules(opts \\ []), to: Jidoka.Schedule.Manager, as: :list

  @doc """
  Cancels and removes a schedule.
  """
  @spec cancel_schedule(String.t() | atom(), keyword()) :: :ok | {:error, term()}
  defdelegate cancel_schedule(id, opts \\ []), to: Jidoka.Schedule.Manager, as: :cancel

  @doc """
  Runs a schedule immediately and waits for the run record.
  """
  @spec run_schedule(String.t() | atom(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate run_schedule(id, opts \\ []), to: Jidoka.Schedule.Manager, as: :run

  @doc """
  Returns the current handoff owner for a conversation, if any.
  """
  @spec handoff_owner(Session.t() | String.t()) :: map() | nil
  def handoff_owner(%Session{} = session), do: Session.handoff_owner(session)
  def handoff_owner(conversation_id), do: Jidoka.Handoff.Registry.owner(conversation_id)

  @doc """
  Clears the current handoff owner for a conversation.
  """
  @spec reset_handoff(Session.t() | String.t()) :: :ok
  def reset_handoff(%Session{} = session), do: Session.reset_handoff(session)
  def reset_handoff(conversation_id), do: Jidoka.Handoff.Registry.reset(conversation_id)

  @doc """
  Returns Jidoka's inspection view of an agent definition or running agent.

  Accepted inputs:

  - a compiled Jidoka agent module
  - an imported Jidoka agent struct
  - a dynamic-agent compatibility struct
  - a running agent PID
  - a running agent ID string
  """
  @spec inspect_agent(module() | struct() | pid() | String.t()) :: {:ok, map()} | {:error, term()}
  def inspect_agent(target), do: Jidoka.Inspection.inspect_agent(target)

  @doc """
  Returns Jidoka's inspection view of a compiled workflow definition.
  """
  @spec inspect_workflow(module()) :: {:ok, map()} | {:error, term()}
  def inspect_workflow(workflow_module), do: Jidoka.Inspection.inspect_workflow(workflow_module)

  @doc """
  Returns a summary for the latest request on a running Jidoka agent.
  """
  @spec inspect_request(Session.t() | pid() | String.t() | Jido.Agent.t()) ::
          {:ok, map()} | {:error, term()}
  def inspect_request(%Session{} = session), do: Jidoka.Inspection.inspect_request(session)
  def inspect_request(target), do: Jidoka.Inspection.inspect_request(target)

  @doc """
  Returns a summary for a specific request on an agent.
  """
  @spec inspect_request(Session.t() | pid() | String.t() | Jido.Agent.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def inspect_request(%Session{} = session, request_id), do: Jidoka.Inspection.inspect_request(session, request_id)
  def inspect_request(target, request_id), do: Jidoka.Inspection.inspect_request(target, request_id)

  @doc """
  Returns the latest structured runtime trace for a running Jidoka agent.
  """
  @spec inspect_trace(Session.t() | pid() | String.t() | Jido.Agent.t()) ::
          {:ok, Jidoka.Trace.t()} | {:error, term()}
  def inspect_trace(%Session{} = session), do: Session.trace(session)
  def inspect_trace(target), do: Jidoka.Trace.latest(target)

  @doc """
  Returns the structured runtime trace for a specific request.
  """
  @spec inspect_trace(Session.t() | pid() | String.t() | Jido.Agent.t(), String.t()) ::
          {:ok, Jidoka.Trace.t()} | {:error, term()}
  def inspect_trace(%Session{} = session, request_id), do: Jidoka.Trace.for_request(session.agent_id, request_id)
  def inspect_trace(target, request_id), do: Jidoka.Trace.for_request(target, request_id)

  @doc """
  Manually compacts the current conversation for a running Jidoka agent.

  Agents must opt in with `lifecycle.compaction`. The original `Jido.Thread`
  remains intact; compaction only affects future provider-facing turns.
  """
  @spec compact(Session.t() | pid() | String.t() | Jido.Agent.t(), keyword()) ::
          {:ok, Jidoka.Compaction.t()} | {:error, term()}
  defdelegate compact(target, opts \\ []), to: Jidoka.Compaction

  @doc """
  Returns the latest compaction snapshot for a running Jidoka agent, if any.
  """
  @spec inspect_compaction(Session.t() | pid() | String.t() | Jido.Agent.t(), keyword()) ::
          {:ok, Jidoka.Compaction.t() | nil} | {:error, term()}
  defdelegate inspect_compaction(target, opts \\ []), to: Jidoka.Compaction
end
