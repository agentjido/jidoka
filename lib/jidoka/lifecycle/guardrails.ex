defmodule Jidoka.Guardrails do
  @moduledoc false

  alias Jido.AI.Request
  alias Jidoka.Guardrails.{Config, Input, Output, Runner, Tool}
  alias Jidoka.Interrupt

  @stages [:input, :output, :tool]

  @type stage :: :input | :output | :tool
  @type guardrail_ref ::
          module()
          | Jidoka.Control.Operation.t()
          | {module(), atom(), [term()]}
          | (term() -> Jidoka.Control.decision())
  @type stage_map :: %{
          input: [guardrail_ref()],
          output: [guardrail_ref()],
          tool: [guardrail_ref()]
        }

  @spec default_stage_map() :: stage_map()
  def default_stage_map do
    Config.default_stage_map()
  end

  @spec normalize_dsl_guardrails(stage_map()) :: {:ok, stage_map()} | {:error, String.t()}
  def normalize_dsl_guardrails(guardrails) when is_map(guardrails) do
    Config.normalize_dsl_guardrails(guardrails)
  end

  @spec normalize_request_guardrails(term()) :: {:ok, stage_map()} | {:error, term()}
  def normalize_request_guardrails(guardrails),
    do: Config.normalize_request_guardrails(guardrails)

  @spec validate_dsl_guardrail_ref(stage(), term()) :: :ok | {:error, String.t()}
  def validate_dsl_guardrail_ref(stage, ref) when stage in @stages do
    Config.validate_dsl_guardrail_ref(stage, ref)
  end

  @spec attach_request_guardrails(map(), stage_map()) :: map()
  def attach_request_guardrails(context, guardrails)
      when is_map(context) and is_map(guardrails) do
    Config.attach_request_guardrails(context, guardrails)
  end

  @spec on_before_cmd(Jido.Agent.t(), term(), stage_map()) :: {:ok, Jido.Agent.t(), term()}
  def on_before_cmd(agent, {:ai_react_start, %{query: query} = params}, defaults) do
    request_id = params[:request_id] || agent.state[:last_request_id]
    {request_guardrails, params} = Config.pop_request_guardrails(params)
    guardrails = combine(defaults, request_guardrails)
    context = Map.get(params, :tool_context, %{}) || %{}

    input = %Input{
      agent: agent,
      server: self(),
      request_id: request_id,
      message: query,
      context: context,
      allowed_tools: Map.get(params, :allowed_tools),
      llm_opts: Map.get(params, :llm_opts, []),
      metadata: %{},
      request_opts: params
    }

    guardrail_meta = %{
      guardrails: guardrails,
      message: input.message,
      context: input.context,
      allowed_tools: input.allowed_tools,
      llm_opts: input.llm_opts,
      request_opts: input.request_opts,
      metadata: input.metadata
    }

    case Runner.run_input(guardrails.input, input) do
      :ok ->
        params =
          Map.update(params, :tool_context, %{}, fn tool_context ->
            tool_context
            |> Kernel.||(%{})
            |> maybe_attach_tool_guardrail_callback(guardrails.tool, agent, request_id)
          end)

        {:ok, put_request_guardrail_meta(agent, request_id, guardrail_meta), {:ai_react_start, params}}

      {:error, label, reason} ->
        error = Runner.normalize_guardrail_error(:input, label, reason, agent, request_id)

        agent =
          agent
          |> Request.fail_request(request_id, error)
          |> put_request_guardrail_meta(request_id, Map.put(guardrail_meta, :error, error))

        {:ok, agent, {:ai_react_request_error, %{request_id: request_id, reason: :guardrail_blocked, message: query}}}

      {:interrupt, label, %Interrupt{} = interrupt} ->
        agent =
          agent
          |> Request.fail_request(request_id, {:interrupt, interrupt})
          |> put_request_guardrail_meta(
            request_id,
            guardrail_meta
            |> Map.put(:interrupt, interrupt)
            |> Map.put(:interrupt_guardrail, label)
          )

        Jidoka.Hooks.notify_interrupt(agent, request_id, interrupt)

        {:ok, agent, {:ai_react_request_error, %{request_id: request_id, reason: :interrupt, message: query}}}
    end
  end

  def on_before_cmd(agent, action, _defaults), do: {:ok, agent, action}

  @spec on_after_cmd(Jido.Agent.t(), term(), [term()], stage_map()) ::
          {:ok, Jido.Agent.t(), [term()]}
  def on_after_cmd(agent, {:ai_react_start, %{request_id: request_id}}, directives, _defaults) do
    run_output_guardrails(agent, request_id, directives)
  end

  def on_after_cmd(agent, _action, directives, _defaults) do
    run_output_guardrails(agent, agent.state[:last_request_id], directives)
  end

  @spec combine(stage_map(), stage_map()) :: stage_map()
  def combine(defaults, request_guardrails) do
    Config.combine(defaults, request_guardrails)
  end

  defp maybe_attach_tool_guardrail_callback(context, [], _agent, _request_id), do: context

  defp maybe_attach_tool_guardrail_callback(context, tool_guardrails, agent, request_id)
       when is_map(context) and is_binary(request_id) do
    callback = fn %{
                    tool_name: tool_name,
                    tool_call_id: tool_call_id,
                    arguments: arguments,
                    context: runtime_context
                  } ->
      input = %Tool{
        agent: agent,
        server: self(),
        request_id: request_id,
        tool_name: tool_name,
        tool_call_id: tool_call_id,
        arguments: arguments,
        context: runtime_context,
        metadata: %{},
        request_opts: %{}
      }

      case Runner.run_guardrails(tool_guardrails, input) do
        :ok ->
          :ok

        {:error, label, reason} ->
          {:error, Runner.normalize_guardrail_error(:tool, label, reason, agent, request_id)}

        {:interrupt, _label, %Interrupt{} = interrupt} ->
          Jidoka.Hooks.notify_interrupt(agent, request_id, interrupt)
          {:interrupt, interrupt}
      end
    end

    Map.put(context, Config.tool_guardrail_callback_key(), callback)
  end

  defp maybe_attach_tool_guardrail_callback(context, _tool_guardrails, _agent, _request_id),
    do: context

  defp put_request_guardrail_meta(agent, request_id, guardrail_meta) do
    update_in(agent.state, [:requests, request_id], fn
      nil ->
        %{meta: %{jidoka_guardrails: guardrail_meta}}

      request ->
        meta =
          request
          |> Map.get(:meta, %{})
          |> Map.put(:jidoka_guardrails, guardrail_meta)

        Map.put(request, :meta, meta)
    end)
    |> then(&%{agent | state: &1})
  end

  defp get_request_guardrail_meta(agent, request_id) do
    get_in(agent.state, [:requests, request_id, :meta, :jidoka_guardrails])
  end

  defp run_output_guardrails(agent, request_id, directives) when is_binary(request_id) do
    case {get_request_guardrail_meta(agent, request_id), current_outcome(agent, request_id)} do
      {%{} = meta, outcome} when not is_nil(outcome) ->
        if Map.get(meta, :output_applied?, false) do
          {:ok, agent, directives}
        else
          input = %Output{
            agent: agent,
            server: self(),
            request_id: request_id,
            message: meta[:message] || "",
            context: meta[:context] || %{},
            allowed_tools: meta[:allowed_tools],
            llm_opts: meta[:llm_opts] || [],
            metadata: meta[:metadata] || %{},
            request_opts: meta[:request_opts] || %{},
            outcome: outcome
          }

          case Runner.run_output(get_in(meta, [:guardrails, :output]) || [], input) do
            :ok ->
              {:ok,
               put_request_guardrail_meta(
                 agent,
                 request_id,
                 Map.put(meta, :output_applied?, true)
               ), directives}

            {:error, label, reason} ->
              error = Runner.normalize_guardrail_error(:output, label, reason, agent, request_id)

              agent =
                agent
                |> force_request_failure(request_id, error)
                |> put_request_guardrail_meta(
                  request_id,
                  meta
                  |> Map.put(:output_applied?, true)
                  |> Map.put(:error, error)
                )

              {:ok, agent, directives}

            {:interrupt, label, %Interrupt{} = interrupt} ->
              agent =
                agent
                |> force_request_failure(request_id, {:interrupt, interrupt})
                |> put_request_guardrail_meta(
                  request_id,
                  meta
                  |> Map.put(:output_applied?, true)
                  |> Map.put(:interrupt, interrupt)
                  |> Map.put(:interrupt_guardrail, label)
                )

              Jidoka.Hooks.notify_interrupt(agent, request_id, interrupt)
              {:ok, agent, directives}
          end
        end

      _ ->
        {:ok, agent, directives}
    end
  end

  defp run_output_guardrails(agent, _request_id, directives), do: {:ok, agent, directives}

  defp force_request_failure(agent, request_id, error) do
    state =
      update_in(agent.state, [:requests, request_id], fn
        nil ->
          %{status: :failed, error: error, completed_at: System.system_time(:millisecond)}

        req ->
          req
          |> Map.put(:status, :failed)
          |> Map.put(:error, error)
          |> Map.put(:completed_at, System.system_time(:millisecond))
          |> Map.delete(:result)
      end)

    %{agent | state: Map.put(state, :completed, true)}
  end

  defp current_outcome(agent, request_id) do
    case Request.get_result(agent, request_id) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, error}
      _ -> nil
    end
  end
end
