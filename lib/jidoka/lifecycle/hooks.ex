defmodule Jidoka.Hooks do
  @moduledoc false

  alias Jido.AI.Request
  alias Jidoka.{Handoff, Interrupt}
  alias Jidoka.Hooks.{AfterTurn, BeforeTurn}
  alias Jidoka.Lifecycle.PhaseSpec
  alias Jidoka.Hooks.Runner

  @request_hooks_key :__jidoka_hooks__
  @stages [:before_turn, :after_turn, :on_interrupt]

  @type stage :: :before_turn | :after_turn | :on_interrupt
  @type hook_ref :: module() | {module(), atom(), [term()]} | (term() -> term())
  @type stage_map :: %{
          before_turn: [hook_ref()],
          after_turn: [hook_ref()],
          on_interrupt: [hook_ref()]
        }

  @spec default_stage_map() :: stage_map()
  def default_stage_map do
    Jidoka.StageRefs.default_stage_map(@stages)
  end

  @spec translate_chat_result({:ok, term()} | {:error, term()} | {:interrupt, Interrupt.t()} | {:handoff, Handoff.t()}) ::
          {:ok, term()} | {:error, term()} | {:interrupt, Interrupt.t()} | {:handoff, Handoff.t()}
  def translate_chat_result({:error, {:handoff, %Handoff{} = handoff}}),
    do: {:handoff, handoff}

  def translate_chat_result({:error, {:failed, _status, {:handoff, %Handoff{} = handoff}}}),
    do: {:handoff, handoff}

  def translate_chat_result({:ok, {:handoff, %Handoff{} = handoff}}),
    do: {:handoff, handoff}

  def translate_chat_result({:error, {:interrupt, %Interrupt{} = interrupt}}),
    do: {:interrupt, interrupt}

  def translate_chat_result({:error, {:failed, _status, {:interrupt, %Interrupt{} = interrupt}}}),
    do: {:interrupt, interrupt}

  def translate_chat_result({:error, {:failed, _status, reason}}),
    do: {:error, reason}

  def translate_chat_result({:ok, {:interrupt, %Interrupt{} = interrupt}}),
    do: {:interrupt, interrupt}

  def translate_chat_result(other), do: other

  @spec notify_interrupt(Jido.Agent.t(), String.t(), Interrupt.t()) :: :ok
  def notify_interrupt(agent, request_id, %Interrupt{} = interrupt) when is_binary(request_id) do
    hook_meta = get_request_hook_meta(agent, request_id) || %{}
    timeouts = hook_meta[:timeouts] || Jidoka.Lifecycle.Timeouts.default().hooks

    Runner.invoke_interrupt_hooks(
      get_in(hook_meta, [:hooks, :on_interrupt]) || [],
      Runner.interrupt_input(agent, request_id, hook_meta, interrupt),
      timeouts.on_interrupt
    )
  end

  def notify_interrupt(_agent, _request_id, _interrupt), do: :ok

  @spec normalize_dsl_hooks(stage_map()) :: {:ok, stage_map()} | {:error, String.t()}
  def normalize_dsl_hooks(hooks) when is_map(hooks) do
    Jidoka.StageRefs.normalize_dsl(hooks, stage_ref_opts())
  end

  @spec normalize_request_hooks(term()) :: {:ok, stage_map()} | {:error, term()}
  def normalize_request_hooks(hooks),
    do: Jidoka.StageRefs.normalize_request(hooks, stage_ref_opts())

  @spec validate_dsl_hook_ref(stage(), term()) :: :ok | {:error, String.t()}
  def validate_dsl_hook_ref(stage, ref) when stage in @stages do
    Jidoka.StageRefs.validate_dsl_ref(stage, ref, stage_ref_opts())
  end

  @spec attach_request_hooks(map(), stage_map()) :: map()
  def attach_request_hooks(context, hooks) when is_map(context) and is_map(hooks) do
    maybe_attach_request_hooks(context, hooks)
  end

  @spec on_before_cmd(module(), Jido.Agent.t(), term(), stage_map(), map(), map()) ::
          {:ok, Jido.Agent.t(), term()}
  def on_before_cmd(
        agent_module,
        agent,
        action,
        defaults,
        default_context,
        timeouts \\ Jidoka.Lifecycle.Timeouts.default().hooks
      )

  def on_before_cmd(
        _agent_module,
        agent,
        {:ai_react_start, %{query: query} = params},
        defaults,
        default_context,
        timeouts
      ) do
    request_id = params[:request_id] || agent.state[:last_request_id]

    params =
      params
      |> merge_default_context(default_context)
      |> attach_runtime_context(agent, self(), request_id)

    {request_hooks, params} = pop_request_hooks(params)
    hooks = combine(defaults, request_hooks)

    input = %BeforeTurn{
      agent: agent,
      server: self(),
      request_id: request_id,
      message: query,
      context: Map.get(params, :tool_context, %{}) || %{},
      allowed_tools: Map.get(params, :allowed_tools),
      llm_opts: Map.get(params, :llm_opts, []),
      metadata: %{},
      request_opts: params
    }

    with {:ok, input} <- Runner.run_before_turn(hooks.before_turn, input, timeouts.before_turn) do
      agent =
        put_request_hook_meta(agent, request_id, %{
          hooks: hooks,
          timeouts: timeouts,
          metadata: input.metadata,
          request_opts: input.request_opts,
          message: input.message,
          context: input.context,
          allowed_tools: input.allowed_tools,
          llm_opts: input.llm_opts
        })

      {:ok, agent, {:ai_react_start, Runner.apply_before_turn_input(params, input)}}
    else
      {:interrupt, %Interrupt{} = interrupt} ->
        hook_meta = %{
          hooks: hooks,
          timeouts: timeouts,
          metadata: input.metadata,
          request_opts: input.request_opts,
          message: input.message,
          context: input.context,
          allowed_tools: input.allowed_tools,
          llm_opts: input.llm_opts,
          interrupt: interrupt
        }

        agent =
          agent
          |> Request.fail_request(request_id, {:interrupt, interrupt})
          |> put_request_hook_meta(request_id, hook_meta)

        Runner.invoke_interrupt_hooks(
          hooks.on_interrupt,
          Runner.interrupt_input(agent, request_id, hook_meta, interrupt),
          timeouts.on_interrupt
        )

        {:ok, agent, {:ai_react_request_error, %{request_id: request_id, reason: :interrupt, message: query}}}

      {:error, reason} ->
        error = Runner.normalize_hook_error(:before_turn, reason, agent, request_id)

        agent =
          agent
          |> Request.fail_request(request_id, error)
          |> put_request_hook_meta(request_id, %{
            hooks: hooks,
            timeouts: timeouts,
            metadata: input.metadata,
            request_opts: input.request_opts,
            message: input.message,
            context: input.context,
            allowed_tools: input.allowed_tools,
            llm_opts: input.llm_opts,
            error: error
          })

        {:ok, agent, {:ai_react_request_error, %{request_id: request_id, reason: :hook_failed, message: query}}}
    end
  end

  def on_before_cmd(_agent_module, agent, action, _defaults, _default_context, _timeouts),
    do: {:ok, agent, action}

  @doc false
  @spec before_phase_specs(module(), stage_map(), map(), map()) :: [PhaseSpec.t()]
  def before_phase_specs(runtime_module, hooks, default_context, timeouts \\ Jidoka.Lifecycle.Timeouts.default().hooks)
      when is_atom(runtime_module) and is_map(default_context) do
    [
      PhaseSpec.before(:hooks_before, :hooks, fn agent, action ->
        on_before_cmd(runtime_module, agent, action, hooks, default_context, timeouts)
      end)
    ]
  end

  @spec on_after_cmd(module(), Jido.Agent.t(), term(), [term()], stage_map(), map()) ::
          {:ok, Jido.Agent.t(), [term()]}
  def on_after_cmd(
        agent_module,
        agent,
        action,
        directives,
        defaults,
        timeouts \\ Jidoka.Lifecycle.Timeouts.default().hooks
      )

  def on_after_cmd(
        _agent_module,
        agent,
        {:ai_react_start, %{request_id: request_id}},
        directives,
        _defaults,
        timeouts
      ) do
    run_after_turn_hooks(agent, request_id, directives, timeouts)
  end

  def on_after_cmd(_agent_module, agent, _action, directives, _defaults, timeouts) do
    run_after_turn_hooks(agent, agent.state[:last_request_id], directives, timeouts)
  end

  @doc false
  @spec after_phase_specs(module(), stage_map(), map()) :: [PhaseSpec.t()]
  def after_phase_specs(runtime_module, hooks, timeouts \\ Jidoka.Lifecycle.Timeouts.default().hooks)
      when is_atom(runtime_module) do
    [
      PhaseSpec.after_phase(:hooks_after, :hooks, fn agent, action, directives ->
        on_after_cmd(runtime_module, agent, action, directives, hooks, timeouts)
      end)
    ]
  end

  @spec combine(stage_map(), stage_map()) :: stage_map()
  def combine(defaults, request_hooks) do
    Jidoka.StageRefs.combine(@stages, defaults, request_hooks)
  end

  defp stage_ref_opts do
    [
      stages: @stages,
      spec_label: "hooks",
      ref_label: "hook",
      invalid_stage: :invalid_hook_stage,
      invalid_spec: :invalid_hook_spec,
      invalid_ref: :invalid_hook,
      module_validator: &Jidoka.Hook.validate_hook_module/1,
      dsl_function_error: "DSL hooks do not support anonymous functions; use a Jidoka.Hook module or MFA instead",
      invalid_ref_message: fn other ->
        "hook refs must be a Jidoka.Hook module, MFA tuple, or runtime function, got: #{inspect(other)}"
      end
    ]
  end

  defp maybe_attach_request_hooks(context, hooks) do
    if hooks == default_stage_map() do
      context
    else
      Map.put(context, @request_hooks_key, hooks)
    end
  end

  defp merge_default_context(params, default_context) when is_map(default_context) do
    merged_context =
      default_context
      |> Jidoka.Context.merge(Map.get(params, :tool_context, %{}) || %{})

    Map.put(params, :tool_context, merged_context)
  end

  defp attach_runtime_context(params, agent, server, request_id)
       when is_map(params) and is_pid(server) and is_binary(request_id) do
    Map.update(params, :tool_context, %{}, fn context ->
      context
      |> Map.put(Jidoka.Subagent.Context.server_key(), server)
      |> Map.put(Jidoka.Subagent.Context.request_id_key(), request_id)
      |> Map.put(Jidoka.Trace.agent_id_key(), Map.get(agent, :id))
    end)
  end

  defp attach_runtime_context(params, _agent, _server, _request_id), do: params

  defp pop_request_hooks(params) when is_map(params) do
    context = Map.get(params, :tool_context, %{}) || %{}
    {request_hooks, context} = Map.pop(context, @request_hooks_key, default_stage_map())
    {request_hooks, Map.put(params, :tool_context, context)}
  end

  defp current_outcome(agent, request_id) do
    case Request.get_result(agent, request_id) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, error}
      _ -> nil
    end
  end

  defp persist_outcome(agent, request_id, {:ok, result}, hook_meta) do
    agent
    |> Request.complete_request(request_id, result)
    |> put_request_hook_meta(request_id, hook_meta)
  end

  defp persist_outcome(agent, request_id, {:error, reason}, hook_meta) do
    agent
    |> Request.fail_request(request_id, reason)
    |> put_request_hook_meta(request_id, hook_meta)
  end

  defp put_request_hook_meta(agent, request_id, hook_meta) do
    update_in(agent.state, [:requests, request_id], fn
      nil ->
        %{meta: %{jidoka_hooks: hook_meta}}

      request ->
        meta =
          request
          |> Map.get(:meta, %{})
          |> Map.put(:jidoka_hooks, hook_meta)

        Map.put(request, :meta, meta)
    end)
    |> then(&%{agent | state: &1})
  end

  defp get_request_hook_meta(agent, request_id) do
    get_in(agent.state, [:requests, request_id, :meta, :jidoka_hooks])
  end

  defp run_after_turn_hooks(agent, request_id, directives, default_timeouts) when is_binary(request_id) do
    hook_meta = get_request_hook_meta(agent, request_id)

    case {hook_meta, current_outcome(agent, request_id)} do
      {%{} = hook_meta, outcome} when not is_nil(outcome) ->
        if Map.get(hook_meta, :after_turn_applied?, false) do
          {:ok, agent, directives}
        else
          timeouts = hook_meta[:timeouts] || default_timeouts

          input = %AfterTurn{
            agent: agent,
            server: self(),
            request_id: request_id,
            message: hook_meta[:message] || "",
            context: hook_meta[:context] || %{},
            allowed_tools: hook_meta[:allowed_tools],
            llm_opts: hook_meta[:llm_opts] || [],
            metadata: hook_meta[:metadata] || %{},
            request_opts: hook_meta[:request_opts] || %{},
            outcome: outcome
          }

          case Runner.run_after_turn(get_in(hook_meta, [:hooks, :after_turn]) || [], input, timeouts.after_turn) do
            {:ok, input} ->
              updated_hook_meta =
                hook_meta
                |> Map.put(:metadata, input.metadata)
                |> Map.put(:after_turn_applied?, true)

              agent =
                persist_outcome(agent, request_id, input.outcome, updated_hook_meta)

              {:ok, agent, directives}

            {:interrupt, %Interrupt{} = interrupt} ->
              hook_meta = Map.put(hook_meta, :after_turn_applied?, true)

              agent =
                agent
                |> Request.fail_request(request_id, {:interrupt, interrupt})
                |> put_request_hook_meta(request_id, Map.put(hook_meta, :interrupt, interrupt))

              Runner.invoke_interrupt_hooks(
                get_in(hook_meta, [:hooks, :on_interrupt]) || [],
                Runner.interrupt_input(agent, request_id, hook_meta, interrupt),
                timeouts.on_interrupt
              )

              {:ok, agent, directives}

            {:error, reason} ->
              error = Runner.normalize_hook_error(:after_turn, reason, agent, request_id)

              agent =
                agent
                |> Request.fail_request(request_id, error)
                |> put_request_hook_meta(
                  request_id,
                  hook_meta
                  |> Map.put(:after_turn_applied?, true)
                  |> Map.put(:error, error)
                )

              {:ok, agent, directives}
          end
        end

      _ ->
        {:ok, agent, directives}
    end
  end

  defp run_after_turn_hooks(agent, _request_id, directives, _default_timeouts), do: {:ok, agent, directives}
end
