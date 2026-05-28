defmodule Jidoka.Chat do
  @moduledoc false

  alias Jido.AI.Request
  alias Jidoka.Chat.Stream, as: ChatStream

  @spec chat(Jidoka.Session.t() | pid() | atom() | {:via, module(), term()} | String.t(), String.t(), keyword()) ::
          {:ok, term()}
          | {:ok, ChatStream.t()}
          | {:error, term()}
          | {:interrupt, Jidoka.Interrupt.t()}
          | {:handoff, Jidoka.Handoff.t()}
  def chat(server_or_id, message, opts \\ [])

  def chat(%Jidoka.Session{} = session, message, opts) when is_binary(message) and is_list(opts) do
    if stream_requested?(opts) do
      chat_stream(session, message, opts)
    else
      with {:ok, request} <- start_chat_request(session, message, opts) do
        await_chat_request(request, opts)
      end
    end
  end

  def chat(server_or_id, message, opts) when is_binary(message) and is_list(opts) do
    if stream_requested?(opts) do
      chat_stream(server_or_id, message, opts)
    else
      with {:ok, request} <- start_chat_request(server_or_id, message, opts) do
        await_chat_request(request, opts)
      end
    end
  end

  @spec chat_stream(
          Jidoka.Session.t() | pid() | atom() | {:via, module(), term()} | String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, ChatStream.t()} | {:error, term()}
  def chat_stream(server_or_id, message, opts \\ [])

  def chat_stream(server_or_id, message, opts) when is_binary(message) and is_list(opts) do
    with {:ok, stream_opts} <- prepare_stream_opts(opts),
         {:ok, request} <- start_chat_request(server_or_id, message, stream_opts) do
      {:ok, ChatStream.new(request, ChatStream.events(request, stream_opts))}
    end
  end

  @spec start_chat_request(
          Jidoka.Session.t() | pid() | atom() | {:via, module(), term()} | String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, Request.Handle.t()} | {:error, term()}
  def start_chat_request(server_or_id, message, opts \\ [])

  def start_chat_request(%Jidoka.Session{} = session, message, opts)
      when is_binary(message) and is_list(opts) do
    case Jidoka.Session.start_agent(session) do
      {:ok, pid} ->
        start_chat_request(pid, message, Jidoka.Session.chat_opts(session, opts))

      {:error, reason} ->
        normalize_start_chat_result({:error, reason}, session.agent_id, opts)
    end
  end

  def start_chat_request(server_or_id, message, opts) when is_binary(message) and is_list(opts) do
    result =
      with :ok <- validate_conversation_opt(opts),
           {:ok, target} <- route_conversation_owner(server_or_id, opts),
           {:ok, server} <- resolve_server(target, opts),
           {:ok, prepared_opts} <- Jidoka.Agent.Chat.prepare_chat_opts(opts, chat_config(server)) do
        request_opts = Keyword.merge(prepared_opts, signal_type: "ai.react.query", source: "/jidoka/agent")

        Request.create_and_send(server, message, request_opts)
      end

    normalize_start_chat_result(result, server_or_id, opts)
  end

  @spec await_chat_request(Request.Handle.t(), keyword()) ::
          {:ok, term()} | {:error, term()} | {:interrupt, Jidoka.Interrupt.t()} | {:handoff, Jidoka.Handoff.t()}
  def await_chat_request(%Request.Handle{} = request, opts \\ []) when is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    request
    |> Request.await(timeout: timeout)
    |> then(&finalize_chat_request(request.server, request.id, &1))
    |> Jidoka.Hooks.translate_chat_result()
    |> normalize_chat_result(request.server, opts)
  end

  @spec chat_request(pid() | atom() | {:via, module(), term()}, String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def chat_request(server, message, opts) when is_binary(message) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    request_opts = Keyword.merge(opts, signal_type: "ai.react.query", source: "/jidoka/agent")

    with {:ok, request} <- Request.create_and_send(server, message, request_opts),
         await_result <- Request.await(request, timeout: timeout) do
      finalize_request_result(server, request, await_result)
    end
  end

  @spec finalize_chat_request(pid() | atom() | {:via, module(), term()}, String.t(), term()) ::
          {:ok, term()} | {:error, term()}
  def finalize_chat_request(_server, _request_id, {:error, :timeout} = error), do: error

  def finalize_chat_request(server, request_id, fallback_result) when is_binary(request_id) do
    case Jido.AgentServer.state(server) do
      {:ok, %{agent: agent}} ->
        case Request.get_request(agent, request_id) do
          %{meta: %{jidoka_guardrails: %{interrupt: interrupt}}} ->
            {:error, {:interrupt, interrupt}}

          %{meta: %{jidoka_guardrails: %{error: error}}} ->
            {:error, error}

          %{meta: %{jidoka_hooks: %{interrupt: interrupt}}} ->
            {:error, {:interrupt, interrupt}}

          %{meta: %{jidoka_handoffs: %{calls: [%{outcome: :handoff, handoff: %Jidoka.Handoff{} = handoff} | _]}}} ->
            case Request.get_result(agent, request_id) do
              {:error, {:handoff, %Jidoka.Handoff{} = result_handoff}} ->
                {:error, {:handoff, result_handoff}}

              {:error, {:failed, _status, {:handoff, %Jidoka.Handoff{} = result_handoff}}} ->
                {:error, {:handoff, result_handoff}}

              _ ->
                {:error, {:handoff, handoff}}
            end

          _request ->
            case Request.get_result(agent, request_id) do
              {:pending, _request} -> fallback_result
              nil -> fallback_result
              result -> result
            end
        end

      {:error, _reason} ->
        fallback_result
    end
  end

  defp chat_config(server) do
    case agent_server_state(server) do
      {:ok, %{agent_module: runtime_module}} when is_atom(runtime_module) ->
        if function_exported?(runtime_module, :__jidoka_definition__, 0) do
          definition = runtime_module.__jidoka_definition__()

          %{
            context: Map.get(definition, :context, %{}),
            context_schema: Map.get(definition, :context_schema),
            ash: ash_config(definition)
          }
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp ash_config(%{ash_domain: nil}), do: nil

  defp ash_config(%{ash_domain: domain, requires_actor?: require_actor?}) do
    %{domain: domain, require_actor?: require_actor?}
  end

  defp ash_config(_definition), do: nil

  defp resolve_server(id, opts) when is_binary(id) do
    case Jidoka.Runtime.whereis(id, opts) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  defp resolve_server(pid, _opts) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_found}
  end

  defp resolve_server(module, opts)
       when is_atom(module) do
    if jidoka_agent_module?(module) do
      start_or_reuse_module_agent(module, opts)
    else
      {:ok, module}
    end
  end

  defp resolve_server(server, _opts), do: {:ok, server}

  defp agent_server_state(server) do
    Jido.AgentServer.state(server)
  rescue
    _error -> {:error, :not_found}
  catch
    :exit, _reason -> {:error, :not_found}
  end

  defp jidoka_agent_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :runtime_module, 0) and
      function_exported?(module, :id, 0)
  end

  defp start_or_reuse_module_agent(module, opts) do
    agent_id = module.id()

    case Jidoka.Runtime.whereis(agent_id, opts) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        start_opts =
          opts
          |> Keyword.get(:start_opts, [])
          |> Keyword.put_new(:id, agent_id)

        Jidoka.Runtime.start_agent(module.runtime_module(), start_opts)
    end
  end

  defp validate_conversation_opt(opts) do
    case Keyword.fetch(opts, :conversation) do
      {:ok, conversation_id} when is_binary(conversation_id) ->
        if String.trim(conversation_id) == "" do
          {:error, Jidoka.Error.Normalize.chat_option_error({:invalid_conversation, conversation_id})}
        else
          :ok
        end

      {:ok, conversation_id} ->
        {:error, Jidoka.Error.Normalize.chat_option_error({:invalid_conversation, conversation_id})}

      :error ->
        :ok
    end
  end

  defp route_conversation_owner(default_target, opts) do
    case Keyword.get(opts, :conversation) do
      conversation_id when is_binary(conversation_id) ->
        case Jidoka.Handoff.OwnerStore.owner(conversation_id) do
          %{agent_id: agent_id} when is_binary(agent_id) -> {:ok, agent_id}
          _ -> {:ok, default_target}
        end

      _ ->
        {:ok, default_target}
    end
  end

  defp normalize_chat_result({:error, reason}, target, opts) do
    case Jidoka.Error.Normalize.chat_error(reason,
           target: target,
           timeout: Keyword.get(opts, :timeout, 30_000)
         ) do
      {:handoff, %Jidoka.Handoff{} = handoff} -> {:handoff, handoff}
      error -> {:error, error}
    end
  end

  defp normalize_chat_result({:handoff, %Jidoka.Handoff{} = handoff}, _target, _opts), do: {:handoff, handoff}
  defp normalize_chat_result(result, _target, _opts), do: result

  defp normalize_start_chat_result({:error, reason}, target, opts) do
    {:error,
     Jidoka.Error.Normalize.chat_error(reason,
       target: target,
       timeout: Keyword.get(opts, :timeout, 30_000)
     )}
  end

  defp normalize_start_chat_result(result, _target, _opts), do: result

  defp finalize_request_result(_server, _request, {:error, :timeout} = error), do: error

  defp finalize_request_result(
         server,
         %Request.Handle{id: request_id} = _request,
         fallback_result
       ) do
    finalize_chat_request(server, request_id, fallback_result)
  end

  defp stream_requested?(opts), do: Keyword.get(opts, :stream) == true

  defp prepare_stream_opts(opts) do
    case Keyword.get(opts, :stream_to) do
      nil ->
        {:ok, opts |> Keyword.delete(:stream) |> Keyword.put(:stream_to, {:pid, self()})}

      {:pid, pid} when pid == self() ->
        {:ok, Keyword.delete(opts, :stream)}

      pid when is_pid(pid) and pid == self() ->
        {:ok, opts |> Keyword.delete(:stream) |> Keyword.put(:stream_to, {:pid, pid})}

      stream_to ->
        {:error,
         Jidoka.Error.validation_error(
           "Streaming chat delivers events to the caller process. Omit `:stream_to` or pass `self()`.",
           field: :stream_to,
           value: stream_to,
           details: %{operation: :chat_stream, reason: :stream_to_must_be_caller}
         )}
    end
  end
end
