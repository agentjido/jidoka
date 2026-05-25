defmodule Jidoka.Output.Runtime do
  @moduledoc false

  alias Jido.AI.Request
  alias Jidoka.Output.{Config, Error, Schema}

  @context_key Config.context_key()

  @spec on_before_cmd(Jido.Agent.t(), term(), map() | nil) :: {:ok, Jido.Agent.t(), term()}
  def on_before_cmd(agent, {:ai_react_start, params}, nil), do: {:ok, agent, {:ai_react_start, params}}

  def on_before_cmd(agent, {:ai_react_start, params}, %{} = output) do
    params =
      params
      |> attach_runtime_context(:tool_context, output)
      |> maybe_attach_existing_runtime_context(output)

    request_id = params[:request_id] || agent.state[:last_request_id]
    context = Map.get(params, :tool_context, %{}) || %{}
    agent = put_request_runtime_meta(agent, request_id, context)

    {:ok, agent, {:ai_react_start, params}}
  end

  def on_before_cmd(agent, action, _output), do: {:ok, agent, action}

  @spec on_after_cmd(Jido.Agent.t(), term(), [term()], map() | nil) :: {:ok, Jido.Agent.t(), [term()]}
  def on_after_cmd(agent, _action, directives, nil), do: {:ok, agent, directives}

  def on_after_cmd(agent, {:ai_react_start, %{request_id: request_id} = params}, directives, %{} = output)
      when is_binary(request_id) do
    context =
      params
      |> Map.get(:tool_context, %{})
      |> normalize_context(output, agent, request_id)

    cond do
      raw_mode?(context) ->
        {:ok, agent, directives}

      true ->
        {:ok, finalize(agent, request_id, output, context: context), directives}
    end
  end

  def on_after_cmd(agent, _action, directives, %{} = output) do
    request_id = agent.state[:last_request_id]
    context = normalize_context(%{}, output, agent, request_id)

    cond do
      not is_binary(request_id) ->
        {:ok, agent, directives}

      raw_mode?(context) ->
        {:ok, agent, directives}

      true ->
        {:ok, finalize(agent, request_id, output, context: context), directives}
    end
  end

  @spec finalize(Jido.Agent.t(), String.t(), map(), keyword()) :: Jido.Agent.t()
  def finalize(agent, request_id, %{} = output, opts \\ []) when is_binary(request_id) do
    context = Keyword.get(opts, :context, %{})
    finalize_request(agent, request_id, output, context, opts)
  end

  @spec attach_request_option(map(), term()) :: map()
  def attach_request_option(context, nil), do: context
  def attach_request_option(context, :raw), do: Map.put(context, @context_key, %{mode: :raw})
  def attach_request_option(context, "raw"), do: Map.put(context, @context_key, %{mode: :raw})
  def attach_request_option(context, _other), do: context

  @spec runtime_output(map()) :: map() | nil
  def runtime_output(context) when is_map(context) do
    case Map.get(context, @context_key) || Map.get(context, Atom.to_string(@context_key)) do
      %{output: %{} = output} -> output
      %{} = output -> output
      _other -> nil
    end
  end

  def runtime_output(_context), do: nil

  defp finalize_request(agent, request_id, output, context, opts) do
    case Request.get_request(agent, request_id) do
      %{status: :completed, result: result} = request ->
        if get_in(request, [:meta, :jidoka_output, :applied?]) do
          agent
        else
          do_finalize_result(agent, request_id, output, context, result, opts)
        end

      _request ->
        agent
    end
  end

  defp do_finalize_result(agent, request_id, output, context, result, opts) do
    trace(output, request_id, context, :start, %{attempt: 0})

    case Schema.parse(output, result) do
      {:ok, parsed} ->
        meta = output_meta(output, :validated, result, attempt: 0, applied?: true)
        trace(output, request_id, context, :validated, %{attempt: 0})
        complete_request(agent, request_id, parsed, meta)

      {:error, reason} ->
        maybe_repair(agent, request_id, output, context, result, reason, opts)
    end
  end

  defp maybe_repair(
         agent,
         request_id,
         %{on_validation_error: :repair, retries: retries} = output,
         context,
         result,
         reason,
         opts
       )
       when retries > 0 do
    trace(output, request_id, context, :repair, %{attempt: 1})

    case repair(agent, output, context, result, reason, opts) do
      {:ok, repaired} ->
        meta = output_meta(output, :repaired, result, attempt: 1, applied?: true, validation_error: reason)
        trace(output, request_id, context, :validated, %{attempt: 1})
        complete_request(agent, request_id, repaired, meta)

      {:error, repair_reason} ->
        fail_output(agent, request_id, output, context, result, repair_reason, attempt: 1)
    end
  end

  defp maybe_repair(agent, request_id, output, context, result, reason, _opts) do
    fail_output(agent, request_id, output, context, result, reason, attempt: 0)
  end

  defp repair(agent, output, context, result, reason, opts) do
    repair_fun = Keyword.get(opts, :repair_fun) || Application.get_env(:jidoka, :output_repair_fun)

    repair_fun =
      cond do
        is_function(repair_fun, 5) ->
          repair_fun

        is_function(repair_fun, 4) ->
          fn output, agent, context, result, _reason -> repair_fun.(output, agent, context, result) end

        true ->
          &default_repair/5
      end

    with {:ok, repaired} <- repair_fun.(output, agent, context, result, reason) do
      Schema.validate(output, repaired)
    end
  rescue
    error -> {:error, Error.output_error({:repair_exception, Error.reason_message(error)}, result)}
  end

  defp default_repair(output, agent, context, result, reason) do
    model = Map.get(agent.state || %{}, :model)

    if is_nil(model) do
      {:error, Error.output_error(:missing_repair_model, result)}
    else
      messages = [
        %{
          role: "system",
          content:
            "Extract a JSON object that matches the provided schema from the assistant answer. Return only the structured object."
        },
        %{role: "user", content: repair_prompt(context, result, reason)}
      ]

      llm_opts =
        context
        |> output_llm_opts()
        |> Keyword.delete(:tools)
        |> Keyword.delete(:tool_choice)
        |> Keyword.put(:stream, false)

      case ReqLLM.Generation.generate_object(model, messages, output.schema, llm_opts) do
        {:ok, response} ->
          ReqLLM.Response.unwrap_object(response, json_repair: true)

        {:error, error} ->
          {:error, Error.output_error({:repair_failed, Error.reason_message(error)}, result)}
      end
    end
  end

  defp repair_prompt(context, result, reason) do
    output_context =
      Map.get(context, @context_key) ||
        Map.get(context, Atom.to_string(@context_key)) ||
        %{}

    """
    Original user message:
    #{Map.get(output_context, :user_message, Map.get(output_context, "user_message", ""))}

    Assistant answer:
    #{Error.raw_preview(result)}

    Validation error:
    #{Jidoka.Error.format(reason)}
    """
  end

  defp output_llm_opts(context) do
    case Map.get(context, @context_key) do
      %{llm_opts: llm_opts} when is_list(llm_opts) -> llm_opts
      _other -> []
    end
  end

  defp complete_request(agent, request_id, parsed, meta) do
    Request.complete_request(agent, request_id, parsed, meta: %{jidoka_output: meta})
  end

  defp fail_output(agent, request_id, output, context, result, reason, opts) do
    attempt = Keyword.fetch!(opts, :attempt)
    meta = output_meta(output, :error, result, attempt: attempt, error: reason, applied?: true)
    trace(output, request_id, context, :error, %{attempt: attempt, error: Jidoka.Error.format(reason)})

    agent
    |> force_request_failure(request_id, reason)
    |> put_output_meta(request_id, meta)
  end

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
      |> Map.put(:completed, true)

    %{agent | state: state}
  end

  defp put_output_meta(agent, request_id, meta) do
    state =
      update_in(agent.state, [:requests, request_id], fn
        nil ->
          %{meta: %{jidoka_output: meta}}

        request ->
          request_meta =
            request
            |> Map.get(:meta, %{})
            |> Map.put(:jidoka_output, meta)

          Map.put(request, :meta, request_meta)
      end)

    %{agent | state: state}
  end

  defp put_request_runtime_meta(agent, request_id, context) when is_binary(request_id) and is_map(context) do
    runtime_meta =
      context
      |> Map.get(@context_key, %{})
      |> normalize_runtime_output_context()
      |> Map.take([:mode, :llm_opts])

    state =
      update_in(agent.state, [:requests, request_id], fn
        nil ->
          %{meta: %{jidoka_output_runtime: runtime_meta}}

        request ->
          request_meta =
            request
            |> Map.get(:meta, %{})
            |> Map.put(:jidoka_output_runtime, runtime_meta)

          Map.put(request, :meta, request_meta)
      end)

    %{agent | state: state}
  end

  defp put_request_runtime_meta(agent, _request_id, _context), do: agent

  defp output_meta(output, status, raw, opts) do
    %{
      applied?: Keyword.get(opts, :applied?, false),
      status: status,
      schema_kind: output.schema_kind,
      retries: output.retries,
      on_validation_error: output.on_validation_error,
      attempt: Keyword.get(opts, :attempt, 0),
      raw_preview: Error.raw_preview(raw),
      error: format_meta_error(Keyword.get(opts, :error)),
      validation_error: format_meta_error(Keyword.get(opts, :validation_error))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp format_meta_error(nil), do: nil
  defp format_meta_error(reason), do: Jidoka.Error.format(reason)

  defp attach_runtime_context(params, key, output) do
    Map.update(params, key, output_runtime_context(output, %{}, params), fn context ->
      context
      |> Kernel.||(%{})
      |> Map.put(@context_key, output_runtime_context(output, context, params))
    end)
  end

  defp maybe_attach_existing_runtime_context(params, output) do
    if Map.has_key?(params, :runtime_context) do
      attach_runtime_context(params, :runtime_context, output)
    else
      params
    end
  end

  defp output_runtime_context(output, context, params) do
    existing = Map.get(context || %{}, @context_key, %{})

    existing
    |> normalize_runtime_output_context()
    |> Map.put(:output, output)
    |> Map.put_new(:mode, :structured)
    |> maybe_put_llm_opts(params)
    |> maybe_put_user_message(params)
  end

  defp normalize_runtime_output_context(%{} = context), do: context
  defp normalize_runtime_output_context(_other), do: %{}

  defp maybe_put_llm_opts(output_context, context) do
    case Map.get(context || %{}, :llm_opts) do
      llm_opts when is_list(llm_opts) -> Map.put(output_context, :llm_opts, llm_opts)
      _other -> output_context
    end
  end

  defp maybe_put_user_message(output_context, params) do
    case Map.get(params || %{}, :query) || Map.get(params || %{}, "query") do
      message when is_binary(message) -> Map.put(output_context, :user_message, message)
      _other -> output_context
    end
  end

  defp normalize_context(context, output, agent, request_id) when is_map(context) do
    context =
      case Map.get(context, @context_key) || Map.get(context, Atom.to_string(@context_key)) do
        %{output: %{}} ->
          context

        %{} = output_context ->
          Map.put(context, @context_key, Map.put(output_context, :output, output))

        _other ->
          runtime_context_from_request(agent, request_id, output)
      end

    context
    |> put_agent_id(agent)
    |> put_user_message(agent, request_id)
  end

  defp normalize_context(_context, output, agent, request_id) do
    normalize_context(%{}, output, agent, request_id)
  end

  defp runtime_context_from_request(agent, request_id, output) when is_binary(request_id) do
    output_context =
      agent
      |> get_in([Access.key(:state), :requests, request_id, :meta, :jidoka_output_runtime])
      |> normalize_runtime_output_context()
      |> Map.put(:output, output)
      |> Map.put_new(:mode, :structured)

    %{@context_key => output_context}
  end

  defp runtime_context_from_request(_agent, _request_id, output) do
    %{@context_key => %{output: output, mode: :structured}}
  end

  defp put_agent_id(context, agent) do
    Map.put_new(context, Jidoka.Trace.agent_id_key(), Map.get(agent, :id))
  end

  defp put_user_message(context, agent, request_id) when is_binary(request_id) do
    case get_in(agent.state, [:requests, request_id, :query]) do
      query when is_binary(query) ->
        Map.update(context, @context_key, %{user_message: query}, fn output_context ->
          output_context
          |> normalize_runtime_output_context()
          |> Map.put_new(:user_message, query)
        end)

      _other ->
        context
    end
  end

  defp put_user_message(context, _agent, _request_id), do: context

  defp raw_mode?(context) do
    case Map.get(context, @context_key) || Map.get(context, Atom.to_string(@context_key)) do
      %{mode: :raw} -> true
      %{mode: "raw"} -> true
      _other -> false
    end
  end

  defp trace(output, request_id, context, event, extra) do
    metadata =
      %{
        event: event,
        output: "structured_output",
        request_id: request_id,
        schema_kind: output.schema_kind,
        status: trace_status(event),
        source: :jidoka,
        category: :output,
        agent_id: Map.get(context, Jidoka.Trace.agent_id_key())
      }
      |> then(&Map.merge(Jidoka.Trace.correlation_refs(context), &1))
      |> Map.merge(extra)

    Jidoka.Trace.emit(:output, metadata)
  end

  defp trace_status(:start), do: :running
  defp trace_status(:validated), do: :completed
  defp trace_status(:repair), do: :running
  defp trace_status(:error), do: :failed
end
