defmodule Jidoka.Session do
  @moduledoc """
  Plain data descriptor for a named Jidoka conversation.

  A session is not a process and does not store a transcript. It names the
  runtime agent, conversation id, context lane, and default runtime context used
  for repeated turns through `Jidoka.chat/3`. The running Jido agent process
  still owns state, `Jido.Thread` remains the conversation log, and
  `Jidoka.AgentView` projects messages for UI and debugging surfaces.

  Session-owned data is intentionally small: addressing, startup options,
  runtime context, and metadata. Inspection, tracing, and compaction snapshots
  are projected from the running agent, not stored in the session struct.
  Jidoka V3 does not own durable transcript storage; use an app-owned runtime
  storage boundary when transcripts must survive process or node restarts.
  """

  alias Jidoka.ImportedAgent

  @default_context_ref "default"
  @default_runtime Jidoka.Runtime

  @type agent :: module() | ImportedAgent.t()

  @type t :: %__MODULE__{
          id: String.t(),
          agent: agent(),
          agent_id: String.t(),
          conversation_id: String.t(),
          context_ref: String.t(),
          context: map(),
          runtime: module(),
          start_opts: keyword(),
          metadata: map()
        }

  @enforce_keys [:id, :agent, :agent_id, :conversation_id, :context_ref]
  defstruct [
    :id,
    :agent,
    :agent_id,
    :conversation_id,
    context_ref: @default_context_ref,
    context: %{},
    runtime: @default_runtime,
    start_opts: [],
    metadata: %{}
  ]

  @doc """
  Builds a session descriptor.

  Required options:

  - `:agent` - compiled Jidoka agent module or imported agent
  - `:id` - application-level session id

  Optional options include `:agent_id`, `:conversation_id`, `:context_ref`,
  `:context`, `:runtime`, `:start_opts`, and `:metadata`.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = attrs_map(attrs)

    with {:ok, agent} <- normalize_agent(input(attrs, :agent)),
         {:ok, id} <- normalize_normalized_id(input(attrs, :id), :id),
         {:ok, conversation_id} <-
           normalize_optional_normalized_id(input(attrs, :conversation_id), id, :conversation_id),
         {:ok, context_ref} <- normalize_text(input(attrs, :context_ref, @default_context_ref), :context_ref),
         {:ok, agent_id} <- normalize_agent_id(input(attrs, :agent_id), agent, conversation_id),
         {:ok, context} <- normalize_context(id, input(attrs, :context, %{})),
         {:ok, runtime} <- normalize_runtime(input(attrs, :runtime, @default_runtime)),
         {:ok, start_opts} <- normalize_keyword(input(attrs, :start_opts, []), :start_opts),
         {:ok, metadata} <- normalize_metadata(input(attrs, :metadata, %{})) do
      {:ok,
       %__MODULE__{
         id: id,
         agent: agent,
         agent_id: agent_id,
         conversation_id: conversation_id,
         context_ref: context_ref,
         context: context,
         runtime: runtime,
         start_opts: start_opts,
         metadata: metadata
       }}
    end
  end

  def new(other) do
    {:error,
     Jidoka.Error.validation_error("Session options must be a map or keyword list.",
       field: :session,
       value: other,
       details: %{reason: :invalid_session_options}
     )}
  end

  @doc """
  Builds a session descriptor and raises when invalid.
  """
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, session} -> session
      {:error, reason} -> raise ArgumentError, message: Jidoka.Error.format(reason)
    end
  end

  @doc """
  Builds public chat options for this session.

  Per-turn `:context` values merge over the session context. If the caller
  explicitly passes `:conversation`, that value is preserved; otherwise the
  session conversation id is used.
  """
  @spec chat_opts(t(), keyword()) :: keyword()
  def chat_opts(%__MODULE__{} = session, opts \\ []) when is_list(opts) do
    opts
    |> Keyword.put(:context, merge_chat_context(session.context, Keyword.get(opts, :context, %{})))
    |> Keyword.put_new(:conversation, session.conversation_id)
    |> put_session_refs(session)
  end

  @doc """
  Starts or reuses the runtime agent for this session.
  """
  @spec start_agent(t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_agent(%__MODULE__{} = session, opts \\ []) when is_list(opts) do
    case whereis(session, opts) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> do_start_agent(session, opts)
    end
  end

  @doc """
  Looks up the running runtime agent for this session.
  """
  @spec whereis(t(), keyword()) :: pid() | nil
  def whereis(%__MODULE__{} = session, opts \\ []) when is_list(opts) do
    runtime = Keyword.get(opts, :runtime, session.runtime)
    lookup_opts = merged_start_opts(session, opts)

    if function_exported?(runtime, :whereis, 2) do
      runtime.whereis(session.agent_id, lookup_opts)
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  @doc """
  Projects the running session agent with `Jidoka.Agent.View`.
  """
  @spec snapshot(t(), keyword()) :: {:ok, map()} | {:error, term()}
  def snapshot(%__MODULE__{} = session, opts \\ []) when is_list(opts) do
    case whereis(session, opts) do
      pid when is_pid(pid) ->
        opts =
          opts
          |> Keyword.put_new(:context_ref, session.context_ref)
          |> Keyword.delete(:runtime)

        Jidoka.Agent.View.snapshot(pid, opts)

      nil ->
        {:error, not_running_error(session)}
    end
  end

  @doc """
  Returns the latest retained trace for this session's runtime agent.
  """
  @spec trace(t(), keyword()) :: {:ok, Jidoka.Trace.t()} | {:error, term()}
  def trace(%__MODULE__{} = session, opts \\ []) when is_list(opts) do
    Jidoka.Trace.latest(session.agent_id, opts)
  end

  @doc """
  Returns the current handoff owner for the session conversation.
  """
  @spec handoff_owner(t()) :: map() | nil
  def handoff_owner(%__MODULE__{} = session), do: Jidoka.Handoff.Registry.owner(session.conversation_id)

  @doc """
  Clears handoff ownership for the session conversation.
  """
  @spec reset_handoff(t()) :: :ok
  def reset_handoff(%__MODULE__{} = session), do: Jidoka.Handoff.Registry.reset(session.conversation_id)

  @doc false
  @spec session_refs(t()) :: map()
  def session_refs(%__MODULE__{} = session) do
    %{
      session_id: session.id,
      conversation_id: session.conversation_id,
      agent_id: session.agent_id,
      context_ref: session.context_ref
    }
  end

  @doc false
  @spec default_context_ref() :: String.t()
  def default_context_ref, do: @default_context_ref

  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)
  defp attrs_map(attrs) when is_map(attrs), do: attrs

  defp input(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp normalize_agent(%ImportedAgent{} = agent), do: {:ok, agent}
  defp normalize_agent(nil), do: invalid_agent_error(nil)
  defp normalize_agent(agent) when is_atom(agent), do: {:ok, agent}

  defp normalize_agent(agent), do: invalid_agent_error(agent)

  defp invalid_agent_error(agent) do
    {:error,
     Jidoka.Error.validation_error("Session agent must be a module or imported Jidoka agent.",
       field: :agent,
       value: agent,
       details: %{reason: :invalid_session_agent}
     )}
  end

  defp normalize_optional_normalized_id(nil, default, _field), do: {:ok, default}
  defp normalize_optional_normalized_id(value, _default, field), do: normalize_normalized_id(value, field)

  defp normalize_normalized_id(nil, field), do: invalid_text_error(field, nil)

  defp normalize_normalized_id(value, field) when is_atom(value),
    do: normalize_normalized_id(Atom.to_string(value), field)

  defp normalize_normalized_id(value, field) when is_binary(value) do
    value
    |> normalize_id("")
    |> case do
      "" -> invalid_text_error(field, value)
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_normalized_id(value, field), do: invalid_text_error(field, value)

  defp normalize_text(nil, field), do: invalid_text_error(field, nil)

  defp normalize_text(value, field) when is_atom(value), do: normalize_text(Atom.to_string(value), field)

  defp normalize_text(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> invalid_text_error(field, value)
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_text(value, field), do: invalid_text_error(field, value)

  defp normalize_agent_id(nil, agent, conversation_id), do: {:ok, default_agent_id(agent, conversation_id)}
  defp normalize_agent_id(value, _agent, _conversation_id), do: normalize_text(value, :agent_id)

  defp default_agent_id(%ImportedAgent{spec: %{id: id}}, conversation_id) when is_binary(id) do
    "#{id}-#{conversation_id}"
  end

  defp default_agent_id(module, conversation_id) when is_atom(module) do
    base =
      if Code.ensure_loaded?(module) and function_exported?(module, :id, 0) do
        apply(module, :id, [])
      else
        module
        |> Module.split()
        |> List.last()
        |> Macro.underscore()
      end

    "#{base}-#{conversation_id}"
  end

  defp normalize_context(id, context) do
    with {:ok, runtime_context} <- Jidoka.Context.normalize(context),
         context <- Jidoka.Context.merge(%{session: id}, runtime_context),
         :ok <- Jidoka.Credential.reject_raw_secrets(context, field: :context) do
      {:ok, context}
    end
  end

  defp normalize_runtime(runtime) when is_atom(runtime), do: {:ok, runtime}

  defp normalize_runtime(runtime) do
    {:error,
     Jidoka.Error.validation_error("Session runtime must be a module.",
       field: :runtime,
       value: runtime,
       details: %{reason: :invalid_session_runtime}
     )}
  end

  defp normalize_keyword(value, _field) when is_list(value) do
    if Keyword.keyword?(value), do: {:ok, value}, else: invalid_keyword_error(value)
  end

  defp normalize_keyword(value, field) do
    {:error,
     Jidoka.Error.validation_error("Session #{field} must be a keyword list.",
       field: field,
       value: value,
       details: %{reason: :invalid_session_option}
     )}
  end

  defp normalize_metadata(value) when is_map(value), do: {:ok, value}

  defp normalize_metadata(value) when is_list(value) do
    if Keyword.keyword?(value), do: {:ok, Map.new(value)}, else: invalid_keyword_error(value)
  end

  defp normalize_metadata(value) do
    {:error,
     Jidoka.Error.validation_error("Session metadata must be a map or keyword list.",
       field: :metadata,
       value: value,
       details: %{reason: :invalid_session_metadata}
     )}
  end

  defp normalize_id(value, default) do
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

  defp invalid_text_error(field, value) do
    {:error,
     Jidoka.Error.validation_error("Session #{field} must be a non-empty string.",
       field: field,
       value: value,
       details: %{reason: :invalid_session_id}
     )}
  end

  defp invalid_keyword_error(value) do
    {:error,
     Jidoka.Error.validation_error("Session options must be a keyword list.",
       field: :opts,
       value: value,
       details: %{reason: :invalid_session_option}
     )}
  end

  defp merge_chat_context(session_context, per_turn_context) when is_map(per_turn_context) do
    Jidoka.Context.merge(session_context, per_turn_context)
  end

  defp merge_chat_context(session_context, per_turn_context) when is_list(per_turn_context) do
    if Keyword.keyword?(per_turn_context) do
      Jidoka.Context.merge(session_context, Map.new(per_turn_context))
    else
      per_turn_context
    end
  end

  defp merge_chat_context(_session_context, per_turn_context), do: per_turn_context

  defp put_session_refs(opts, %__MODULE__{} = session) do
    refs = session_refs(session)

    Keyword.update(opts, :extra_refs, refs, fn
      current when is_map(current) -> Map.merge(current, refs)
      current -> current
    end)
  end

  defp do_start_agent(%__MODULE__{} = session, opts) do
    runtime = Keyword.get(opts, :runtime, session.runtime)

    start_opts =
      session
      |> merged_start_opts(opts)
      |> Keyword.put(:id, session.agent_id)
      |> maybe_put_context_ref(session.context_ref)

    result =
      case {session.agent, runtime} do
        {%ImportedAgent{} = agent, @default_runtime} ->
          ImportedAgent.start_link(agent, start_opts)

        {%ImportedAgent{runtime_module: runtime_module}, runtime} ->
          start_via_runtime(runtime, runtime_module, start_opts)

        {agent, @default_runtime} when is_atom(agent) ->
          if Code.ensure_loaded?(agent) and function_exported?(agent, :start_link, 1) do
            apply(agent, :start_link, [start_opts])
          else
            start_via_runtime(@default_runtime, runtime_module(agent), start_opts)
          end

        {agent, runtime} when is_atom(agent) ->
          start_via_runtime(runtime, runtime_module(agent), start_opts)
      end

    normalize_start_result(result, session)
  end

  defp merged_start_opts(%__MODULE__{} = session, opts) do
    opts =
      opts
      |> Keyword.delete(:runtime)
      |> Keyword.delete(:context_ref)

    Keyword.merge(session.start_opts, opts)
  end

  defp maybe_put_context_ref(opts, @default_context_ref), do: opts

  defp maybe_put_context_ref(opts, context_ref) do
    initial_state =
      opts
      |> Keyword.get(:initial_state, %{})
      |> case do
        state when is_map(state) -> Map.put(state, :active_context_ref, context_ref)
        state -> state
      end

    Keyword.put(opts, :initial_state, initial_state)
  end

  defp start_via_runtime(runtime, runtime_module, start_opts) do
    if function_exported?(runtime, :start_agent, 2) do
      runtime.start_agent(runtime_module, start_opts)
    else
      {:error,
       Jidoka.Error.config_error("Session runtime does not expose start_agent/2.",
         field: :runtime,
         value: runtime
       )}
    end
  end

  defp runtime_module(agent) when is_atom(agent) do
    if Code.ensure_loaded?(agent) and function_exported?(agent, :runtime_module, 0) do
      apply(agent, :runtime_module, [])
    else
      agent
    end
  end

  defp normalize_start_result({:ok, pid}, _session) when is_pid(pid), do: {:ok, pid}
  defp normalize_start_result({:ok, pid, _info}, _session) when is_pid(pid), do: {:ok, pid}
  defp normalize_start_result({:error, {:already_registered, pid}}, _session) when is_pid(pid), do: {:ok, pid}

  defp normalize_start_result({:error, _reason} = error, %__MODULE__{} = session) do
    case whereis(session) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> error
    end
  end

  defp normalize_start_result(other, _session), do: other

  defp not_running_error(%__MODULE__{} = session) do
    Jidoka.Error.validation_error("Session agent is not running.",
      field: :session,
      value: session.id,
      details: %{reason: :session_agent_not_running, agent_id: session.agent_id}
    )
  end
end
