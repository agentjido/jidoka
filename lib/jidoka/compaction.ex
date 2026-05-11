defmodule Jidoka.Compaction do
  @moduledoc """
  Summary-based context compaction for long-running Jidoka conversations.

  Compaction is an opt-in lifecycle feature. It keeps the original `Jido.Thread`
  intact and only changes the provider-facing message window for future turns.
  """

  require Logger

  alias Jidoka.Compaction.{Config, Prompt}

  @context_key :__jidoka_compaction__
  @state_key :__jidoka_compaction__

  @type mode :: :auto | :manual | :off
  @type strategy :: :summary
  @type config :: %{
          mode: mode(),
          strategy: strategy(),
          max_messages: pos_integer(),
          keep_last: pos_integer(),
          max_summary_chars: pos_integer(),
          prompt: Prompt.spec() | nil
        }

  @type status :: :summarized | :skipped | :error
  @type t :: %__MODULE__{
          id: String.t(),
          agent_id: term(),
          conversation_id: String.t() | nil,
          request_id: String.t() | nil,
          status: status(),
          strategy: strategy(),
          summary: String.t() | nil,
          summary_preview: String.t() | nil,
          source_message_count: non_neg_integer(),
          retained_message_count: non_neg_integer(),
          started_at_ms: non_neg_integer() | nil,
          completed_at_ms: non_neg_integer() | nil,
          error: term(),
          metadata: map()
        }

  defstruct [
    :id,
    :agent_id,
    :conversation_id,
    :request_id,
    :status,
    :strategy,
    :summary,
    :summary_preview,
    :source_message_count,
    :retained_message_count,
    :started_at_ms,
    :completed_at_ms,
    :error,
    metadata: %{}
  ]

  @doc """
  Returns the runtime context key used to pass compaction data through a turn.
  """
  @spec context_key() :: atom()
  def context_key, do: @context_key

  @doc """
  Returns the agent state key used to store the latest compaction snapshot.
  """
  @spec state_key() :: atom()
  def state_key, do: @state_key

  @doc """
  Returns Jidoka's default summary compaction configuration.
  """
  @spec default_config() :: config()
  def default_config, do: Config.default_config()

  @doc """
  Returns whether a normalized compaction config enables runtime compaction.
  """
  @spec enabled?(config() | nil) :: boolean()
  def enabled?(nil), do: false
  def enabled?(%{mode: :off}), do: false
  def enabled?(%{}), do: true

  @doc false
  @spec normalize_dsl([struct()], module() | nil) :: {:ok, config() | nil} | {:error, String.t()}
  def normalize_dsl(entries, owner_module \\ nil), do: Config.normalize_dsl(entries, owner_module)

  @doc false
  @spec normalize_imported(nil | map()) :: {:ok, config() | nil} | {:error, String.t()}
  def normalize_imported(compaction), do: Config.normalize_imported(compaction)

  @doc false
  @spec validate_dsl_entry(struct(), module() | nil) :: :ok | {:error, String.t()}
  def validate_dsl_entry(entry, owner_module \\ nil), do: Config.validate_dsl_entry(entry, owner_module)

  @doc false
  @spec externalize(config() | nil) :: map() | nil
  def externalize(config), do: Config.externalize(config)

  @doc """
  Returns the prompt section injected for a runtime context with a summary.
  """
  @spec prompt_text(map()) :: String.t() | nil
  def prompt_text(runtime_context) when is_map(runtime_context) do
    runtime_context
    |> runtime_compaction()
    |> case do
      %{summary: summary} when is_binary(summary) and summary != "" ->
        "Compacted conversation summary:\n#{summary}"

      _ ->
        nil
    end
  end

  def prompt_text(_runtime_context), do: nil

  @doc """
  Applies the latest compaction window to provider-facing request messages.

  The original thread is not changed. Tool-call and tool-result adjacency is
  preserved at the retained boundary.
  """
  @spec apply_to_messages([map()], map()) :: [map()]
  def apply_to_messages(messages, runtime_context) when is_list(messages) and is_map(runtime_context) do
    case runtime_compaction(runtime_context) do
      %{summary: summary, keep_last: keep_last} when is_binary(summary) and summary != "" and is_integer(keep_last) ->
        messages
        |> reject_system_messages()
        |> retained_tail(keep_last)

      _ ->
        messages
    end
  end

  def apply_to_messages(messages, _runtime_context), do: messages

  @doc false
  @spec on_before_cmd(Jido.Agent.t(), term(), config() | nil, map()) ::
          {:ok, Jido.Agent.t(), term()}
  def on_before_cmd(agent, action, nil, _default_context), do: {:ok, agent, action}
  def on_before_cmd(agent, action, %{mode: :off}, _default_context), do: {:ok, agent, action}

  def on_before_cmd(agent, {:ai_react_start, params}, %{} = config, default_context) do
    request_id = params[:request_id] || agent.state[:last_request_id]

    params = merge_default_context(params, default_context)
    context = Map.get(params, :tool_context, %{}) || %{}

    {agent, meta} =
      case config.mode do
        :auto ->
          auto_compact(agent, config, params, context, request_id)

        :manual ->
          {agent, %{status: :manual, enabled?: true}}
      end

    context = attach_latest_compaction(context, latest(agent), config)

    params =
      params
      |> Map.put(:tool_context, context)
      |> Map.put(:runtime_context, context)

    agent = put_request_compaction_meta(agent, request_id, Map.merge(meta, request_meta(latest(agent))))

    {:ok, agent, {:ai_react_start, params}}
  end

  def on_before_cmd(agent, action, _config, _default_context), do: {:ok, agent, action}

  @spec compact(Jidoka.Session.t() | pid() | String.t() | Jido.Agent.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  @doc """
  Runs manual compaction for a configured agent target.

  The target may be a `Jidoka.Session`, running pid, registered agent id, or
  `%Jido.Agent{}` snapshot. Sessions must already have a running agent.
  """
  def compact(target, opts \\ [])

  def compact(%Jidoka.Session{} = session, opts) do
    case Jidoka.Session.whereis(session) do
      pid when is_pid(pid) ->
        opts =
          opts
          |> Keyword.put_new(:conversation_id, session.conversation_id)
          |> Keyword.put_new(:context_ref, session.context_ref)

        compact(pid, opts)

      nil ->
        {:error,
         Jidoka.Error.validation_error("Session agent is not running.",
           field: :session,
           value: session.id,
           details: %{reason: :session_agent_not_running, agent_id: session.agent_id}
         )}
    end
  end

  def compact(%Jido.Agent{} = agent, opts) do
    with {:ok, config} <- resolve_manual_config(agent, nil, opts),
         {:ok, updated_agent, %__MODULE__{} = compaction} <-
           run_compaction(agent, config, Keyword.merge(opts, force: true, trigger: :manual)) do
      {:ok, %{compaction | metadata: Map.put(compaction.metadata, :agent, updated_agent.id)}}
    end
  end

  def compact(server_or_id, opts) do
    with {:ok, server} <- resolve_server(server_or_id),
         {:ok, %{agent: %Jido.Agent{} = agent, agent_module: agent_module}} <- Jido.AgentServer.state(server),
         {:ok, config} <- resolve_manual_config(agent, agent_module, opts),
         {:ok, updated_agent, %__MODULE__{} = compaction} <-
           run_compaction(agent, config, Keyword.merge(opts, force: true, trigger: :manual)),
         :ok <- replace_agent(server, updated_agent) do
      {:ok, compaction}
    end
  end

  @spec inspect_compaction(Jidoka.Session.t() | pid() | String.t() | Jido.Agent.t(), keyword()) ::
          {:ok, t() | nil} | {:error, term()}
  @doc """
  Returns the latest compaction snapshot for a target, if one exists.
  """
  def inspect_compaction(target, opts \\ [])

  def inspect_compaction(%Jidoka.Session{} = session, opts) do
    case Jidoka.Session.whereis(session) do
      pid when is_pid(pid) -> inspect_compaction(pid, opts)
      nil -> {:ok, nil}
    end
  end

  def inspect_compaction(%Jido.Agent{} = agent, _opts), do: {:ok, latest(agent)}

  def inspect_compaction(server_or_id, _opts) do
    with {:ok, server} <- resolve_server(server_or_id),
         {:ok, %{agent: %Jido.Agent{} = agent}} <- Jido.AgentServer.state(server) do
      {:ok, latest(agent)}
    end
  end

  @doc false
  @spec runtime_compaction(map()) :: map() | nil
  def runtime_compaction(context) when is_map(context) do
    case Map.get(context, @context_key) || Map.get(context, Atom.to_string(@context_key)) do
      %{compaction: %__MODULE__{} = compaction, keep_last: keep_last} ->
        %{summary: compaction.summary, keep_last: keep_last, compaction: compaction}

      %{summary: summary, keep_last: keep_last} ->
        %{summary: summary, keep_last: keep_last}

      %__MODULE__{} = compaction ->
        %{summary: compaction.summary, keep_last: nil, compaction: compaction}

      _ ->
        nil
    end
  end

  def runtime_compaction(_context), do: nil

  defp auto_compact(agent, config, params, context, request_id) do
    opts = [
      trigger: :auto,
      request_id: request_id,
      conversation_id: conversation_id(context, params),
      context_ref: context_ref(agent, context),
      context: context,
      llm_opts: Map.get(params, :llm_opts, [])
    ]

    case run_compaction(agent, config, opts) do
      {:ok, updated_agent, %__MODULE__{} = compaction} ->
        {updated_agent, request_meta(compaction)}

      {:error, reason} ->
        error = Jidoka.Error.format(reason)
        Logger.warning("Jidoka compaction failed: #{error}")

        trace_compaction(agent, request_id, :error, %{
          error: error,
          trigger: :auto
        })

        {agent, %{status: :error, error: error, trigger: :auto}}
    end
  end

  defp run_compaction(%Jido.Agent{} = agent, %{mode: :off}, opts) do
    {:ok, agent, skipped_compaction(agent, opts, :off, [])}
  end

  defp run_compaction(%Jido.Agent{} = agent, %{} = config, opts) do
    started_at = System.system_time(:millisecond)
    messages = Keyword.get(opts, :messages) || projected_messages(agent, opts)
    message_count = length(messages)
    force? = Keyword.get(opts, :force, false)
    request_id = Keyword.get(opts, :request_id)
    opts = Keyword.put_new(opts, :keep_last, config.keep_last)

    cond do
      not force? and message_count <= config.max_messages ->
        compaction = skipped_compaction(agent, opts, :below_threshold, messages)
        trace_compaction(agent, request_id, :skipped, trace_meta(compaction, %{reason: :below_threshold}))
        {:ok, agent, compaction}

      true ->
        {source_messages, retained_messages} = split_messages(messages, config.keep_last)

        if source_messages == [] do
          compaction = skipped_compaction(agent, opts, :no_source_messages, messages)
          trace_compaction(agent, request_id, :skipped, trace_meta(compaction, %{reason: :no_source_messages}))
          {:ok, agent, compaction}
        else
          summarize(agent, config, opts, source_messages, retained_messages, started_at)
        end
    end
  end

  defp summarize(agent, config, opts, source_messages, retained_messages, started_at) do
    request_id = Keyword.get(opts, :request_id)
    previous = latest_success(agent)
    transcript = transcript_payload(source_messages, previous, config)

    input = %{
      agent: agent,
      config: config,
      context: Keyword.get(opts, :context, %{}),
      previous_summary: previous && previous.summary,
      request_id: request_id,
      source_message_count: length(source_messages),
      retained_message_count: length(retained_messages),
      transcript: transcript
    }

    trace_compaction(agent, request_id, :start, %{
      trigger: Keyword.get(opts, :trigger, :auto),
      source_message_count: length(source_messages),
      retained_message_count: length(retained_messages)
    })

    with {:ok, prompt} <- Prompt.resolve(config.prompt, input),
         {:ok, raw_summary} <- call_summarizer(agent, config, opts, Map.put(input, :prompt, prompt)),
         summary <- normalize_summary(raw_summary, config.max_summary_chars) do
      completed_at = System.system_time(:millisecond)

      compaction = %__MODULE__{
        id: compaction_id(),
        agent_id: Map.get(agent, :id),
        conversation_id: Keyword.get(opts, :conversation_id),
        request_id: request_id,
        status: :summarized,
        strategy: config.strategy,
        summary: summary,
        summary_preview: Jidoka.Sanitize.preview(summary, 240),
        source_message_count: length(source_messages),
        retained_message_count: length(retained_messages),
        started_at_ms: started_at,
        completed_at_ms: completed_at,
        metadata: %{
          trigger: Keyword.get(opts, :trigger, :auto),
          prompt_override?: not is_nil(config.prompt),
          duration_ms: completed_at - started_at
        }
      }

      agent = put_latest(agent, compaction)
      trace_compaction(agent, request_id, :summarized, trace_meta(compaction))
      {:ok, agent, compaction}
    else
      {:error, reason} ->
        completed_at = System.system_time(:millisecond)

        compaction = %__MODULE__{
          id: compaction_id(),
          agent_id: Map.get(agent, :id),
          conversation_id: Keyword.get(opts, :conversation_id),
          request_id: request_id,
          status: :error,
          strategy: config.strategy,
          source_message_count: length(source_messages),
          retained_message_count: length(retained_messages),
          started_at_ms: started_at,
          completed_at_ms: completed_at,
          error: reason,
          metadata: %{trigger: Keyword.get(opts, :trigger, :auto)}
        }

        trace_compaction(agent, request_id, :error, trace_meta(compaction, %{error: Jidoka.Error.format(reason)}))
        {:error, reason}
    end
  end

  defp call_summarizer(agent, config, opts, input) do
    summarizer = Keyword.get(opts, :summarizer) || Application.get_env(:jidoka, :compaction_summarizer)

    cond do
      is_function(summarizer, 1) ->
        normalize_summarizer_result(summarizer.(input))

      is_atom(summarizer) and not is_nil(summarizer) and function_exported?(summarizer, :summarize, 1) ->
        normalize_summarizer_result(summarizer.summarize(input))

      true ->
        default_summarizer(agent, config, opts, input)
    end
  rescue
    error -> {:error, error}
  end

  defp default_summarizer(agent, _config, opts, input) do
    model = Map.get(agent.state, :model) || get_in(agent.state, [:__strategy__, :config, :model])

    if is_nil(model) do
      {:error, :missing_compaction_model}
    else
      messages = [
        %{role: "system", content: input.prompt},
        %{role: "user", content: compaction_user_prompt(input)}
      ]

      llm_opts =
        opts
        |> Keyword.get(:llm_opts, [])
        |> Keyword.delete(:tools)
        |> Keyword.delete(:tool_choice)
        |> Keyword.put(:stream, false)

      case ReqLLM.Generation.generate_text(model, messages, llm_opts) do
        {:ok, response} -> {:ok, Jido.AI.Turn.extract_text(response)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp normalize_summarizer_result({:ok, summary}) when is_binary(summary), do: {:ok, summary}
  defp normalize_summarizer_result(summary) when is_binary(summary), do: {:ok, summary}
  defp normalize_summarizer_result({:error, reason}), do: {:error, reason}
  defp normalize_summarizer_result(other), do: {:error, {:invalid_compaction_summary, other}}

  defp compaction_user_prompt(input) do
    previous =
      case input.previous_summary do
        summary when is_binary(summary) and summary != "" ->
          "Previous compacted summary:\n#{summary}\n\n"

        _ ->
          ""
      end

    """
    #{previous}Transcript to compact:
    #{input.transcript}
    """
  end

  defp normalize_summary(summary, max_chars) when is_binary(summary) do
    summary
    |> String.trim()
    |> String.slice(0, max_chars)
  end

  defp projected_messages(agent, opts) do
    case Jidoka.Agent.View.snapshot(agent, context_ref: Keyword.get(opts, :context_ref)) do
      {:ok, %{llm_context: messages}} when is_list(messages) -> messages
      _ -> []
    end
  end

  defp split_messages(messages, keep_last) do
    messages = reject_system_messages(messages)
    retained = retained_tail(messages, keep_last)
    source_count = max(length(messages) - length(retained), 0)
    {Enum.take(messages, source_count), retained}
  end

  defp retained_tail(messages, keep_last) when length(messages) <= keep_last, do: messages

  defp retained_tail(messages, keep_last) do
    start = max(length(messages) - keep_last, 0)
    start = expand_tool_boundary(messages, start)
    Enum.drop(messages, start)
  end

  defp expand_tool_boundary(_messages, 0), do: 0

  defp expand_tool_boundary(messages, start) do
    first = Enum.at(messages, start)

    if tool_result_message?(first) do
      start
      |> Stream.iterate(&max(&1 - 1, 0))
      |> Enum.find(fn index ->
        index == 0 or assistant_tool_call?(Enum.at(messages, index))
      end)
      |> case do
        nil -> start
        index -> index
      end
    else
      start
    end
  end

  defp reject_system_messages(messages), do: Enum.reject(messages, &(message_role(&1) == :system))

  defp tool_result_message?(message), do: message_role(message) == :tool

  defp assistant_tool_call?(message) do
    message_role(message) == :assistant and
      ((is_list(Map.get(message, :tool_calls)) and Map.get(message, :tool_calls) != []) or
         (is_list(Map.get(message, "tool_calls")) and Map.get(message, "tool_calls") != []))
  end

  defp transcript_payload(messages, previous, config) do
    transcript =
      messages
      |> Enum.map_join("\n", &message_line/1)
      |> String.slice(0, max(config.max_summary_chars * 4, config.max_summary_chars))

    case previous do
      %__MODULE__{summary: summary} when is_binary(summary) and summary != "" ->
        "Existing summary:\n#{summary}\n\nMessages:\n#{transcript}"

      _ ->
        transcript
    end
  end

  defp message_line(message) when is_map(message) do
    role = message_role(message) || :message
    content = message_content(message)
    refs = message_refs(message)
    suffix = if refs == %{}, do: "", else: " refs=#{inspect(refs, limit: 6, printable_limit: 120)}"
    "[#{role}] #{content}#{suffix}"
  end

  defp message_line(other), do: "[message] #{Jidoka.Sanitize.preview(other, 400)}"

  defp message_content(message) do
    cond do
      is_binary(Map.get(message, :content)) ->
        Map.get(message, :content)

      is_binary(Map.get(message, "content")) ->
        Map.get(message, "content")

      true ->
        Jidoka.Sanitize.preview(Map.drop(message, [:id, :seq, :role, "id", "seq", "role"]), 400)
    end
    |> Jidoka.Sanitize.preview(1_000)
  end

  defp message_refs(message) do
    message
    |> Map.take([:request_id, :run_id, :tool_call_id, :name])
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp message_role(%{role: role}), do: normalize_role(role)
  defp message_role(%{"role" => role}), do: normalize_role(role)
  defp message_role(_message), do: nil

  defp normalize_role(role) when role in [:system, :user, :assistant, :tool], do: role

  defp normalize_role(role) when is_binary(role) do
    case role do
      "system" -> :system
      "user" -> :user
      "assistant" -> :assistant
      "tool" -> :tool
      _ -> :message
    end
  end

  defp normalize_role(_role), do: :message

  defp skipped_compaction(agent, opts, reason, messages) do
    %__MODULE__{
      id: compaction_id(),
      agent_id: Map.get(agent, :id),
      conversation_id: Keyword.get(opts, :conversation_id),
      request_id: Keyword.get(opts, :request_id),
      status: :skipped,
      strategy: :summary,
      source_message_count: max(length(messages) - Keyword.get(opts, :keep_last, 0), 0),
      retained_message_count: length(messages),
      started_at_ms: System.system_time(:millisecond),
      completed_at_ms: System.system_time(:millisecond),
      metadata: %{reason: reason, trigger: Keyword.get(opts, :trigger, :auto)}
    }
  end

  defp latest(%Jido.Agent{state: state}) when is_map(state), do: Map.get(state, @state_key)
  defp latest(_agent), do: nil

  defp latest_success(agent) do
    case latest(agent) do
      %__MODULE__{status: :summarized, summary: summary} = compaction when is_binary(summary) and summary != "" ->
        compaction

      _ ->
        nil
    end
  end

  defp put_latest(%Jido.Agent{} = agent, %__MODULE__{} = compaction) do
    %{agent | state: Map.put(agent.state, @state_key, compaction)}
  end

  defp attach_latest_compaction(context, %__MODULE__{status: :summarized, summary: summary} = compaction, config)
       when is_binary(summary) and summary != "" do
    Map.put(context, @context_key, %{
      compaction: compaction,
      summary: summary,
      keep_last: config.keep_last
    })
  end

  defp attach_latest_compaction(context, _compaction, _config), do: context

  defp put_request_compaction_meta(agent, request_id, compaction_meta) when is_binary(request_id) do
    state = agent.state

    update_in(state, [:requests, request_id], fn
      nil ->
        %{meta: %{jidoka_compaction: compaction_meta}}

      request ->
        meta =
          request
          |> Map.get(:meta, %{})
          |> Map.put(:jidoka_compaction, compaction_meta)

        Map.put(request, :meta, meta)
    end)
    |> then(&%{agent | state: &1})
  end

  defp put_request_compaction_meta(agent, _request_id, _compaction_meta), do: agent

  defp request_meta(nil), do: %{}

  defp request_meta(%__MODULE__{} = compaction) do
    %{
      id: compaction.id,
      status: compaction.status,
      strategy: compaction.strategy,
      summary_preview: compaction.summary_preview,
      source_message_count: compaction.source_message_count,
      retained_message_count: compaction.retained_message_count,
      error: compaction.error && Jidoka.Error.format(compaction.error),
      metadata: compaction.metadata
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp trace_compaction(agent, request_id, event, metadata) do
    Jidoka.Trace.emit(
      :compaction,
      Map.merge(
        %{
          event: event,
          request_id: request_id,
          agent_id: Map.get(agent, :id),
          compaction: "summary"
        },
        metadata
      )
    )
  end

  defp trace_meta(%__MODULE__{} = compaction, extra \\ %{}) do
    Map.merge(
      %{
        compaction_id: compaction.id,
        status: compaction.status,
        conversation_id: compaction.conversation_id,
        source_message_count: compaction.source_message_count,
        retained_message_count: compaction.retained_message_count,
        summary_chars: if(is_binary(compaction.summary), do: String.length(compaction.summary), else: nil)
      },
      extra
    )
  end

  defp merge_default_context(params, default_context)
       when is_map(params) and is_map(default_context) do
    context =
      default_context
      |> Jidoka.Context.merge(Map.get(params, :tool_context, %{}) || %{})

    params
    |> Map.put(:tool_context, context)
    |> Map.put(:runtime_context, context)
  end

  defp conversation_id(context, params) do
    get_value(context, :conversation_id) ||
      get_value(context, :conversation) ||
      get_in(params, [:extra_refs, :conversation_id]) ||
      get_in(params, [:extra_refs, "conversation_id"])
  end

  defp context_ref(agent, context) do
    get_value(context, :context_ref) ||
      Map.get(agent.state, :active_context_ref) ||
      get_in(agent.state, [:__strategy__, :active_context_ref]) ||
      "default"
  end

  defp resolve_manual_config(agent, agent_module, opts) do
    cond do
      Keyword.get(opts, :config) ->
        Config.normalize_imported(Keyword.fetch!(opts, :config))

      function_exported?(agent_module, :__jidoka_definition__, 0) ->
        agent_module.__jidoka_definition__()
        |> Map.get(:compaction)
        |> case do
          nil -> {:error, compaction_not_configured(agent)}
          config -> {:ok, config}
        end

      function_exported?(agent.__struct__, :__jidoka_definition__, 0) ->
        agent.__struct__.__jidoka_definition__()
        |> Map.get(:compaction)
        |> case do
          nil -> {:error, compaction_not_configured(agent)}
          config -> {:ok, config}
        end

      true ->
        {:error, compaction_not_configured(agent)}
    end
  end

  defp compaction_not_configured(agent) do
    Jidoka.Error.validation_error("Compaction is not configured for this agent.",
      field: :compaction,
      value: Map.get(agent, :id),
      details: %{reason: :compaction_not_configured}
    )
  end

  defp resolve_server(server) when is_pid(server), do: {:ok, server}

  defp resolve_server(server_id) when is_binary(server_id) do
    case Jidoka.Runtime.whereis(server_id) || Jido.AgentServer.whereis(Jido.Registry, server_id) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :not_found}
    end
  end

  defp resolve_server(server), do: {:ok, server}

  defp replace_agent(server, %Jido.Agent{} = agent) do
    :sys.replace_state(server, fn
      %Jido.AgentServer.State{} = state -> Jido.AgentServer.State.update_agent(state, agent)
      %{agent: _old_agent} = state -> %{state | agent: agent}
      state -> state
    end)

    :ok
  rescue
    error -> {:error, error}
  end

  defp compaction_id do
    "compaction-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp get_value(map, key, default \\ nil)

  defp get_value(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get_value(map, key, default) when is_map(map), do: Map.get(map, key, default)
end
