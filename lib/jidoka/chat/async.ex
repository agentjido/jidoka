defmodule Jidoka.Chat.Async do
  @moduledoc false

  alias Jidoka.Cancellation
  alias Jidoka.Chat.Request
  alias Jidoka.Chat.RequestController

  @spec start_fun(term(), String.t(), keyword(), (keyword() -> term())) ::
          {:ok, Request.t()} | {:error, term()}
  def start_fun(target, input, opts, fun)
      when is_binary(input) and is_list(opts) and is_function(fun, 1) do
    request_id = request_id(opts)
    caller = self()
    opts = prepare_opts(opts, request_id, caller)

    with {:ok, controller} <-
           RequestController.start(
             request_id: request_id,
             owner: caller,
             target: target,
             runtime_opts: opts,
             fun: fun
           ),
         :ok <- RequestController.ready(controller) do
      {:ok,
       Request.new(
         request_id: request_id,
         controller: controller,
         target: target,
         session_id: session_id(target),
         stream_to: stream_to(opts),
         started_at_ms: System.system_time(:millisecond),
         metadata: metadata(opts)
       )}
    end
  rescue
    exception -> {:error, exception}
  end

  @spec await(Request.t(), keyword()) ::
          term() | {:cancelled, Cancellation.t()} | {:error, term()}
  def await(request, opts \\ [])

  def await(%Request{} = request, opts) when is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    with {:ok, controller} <- Request.controller(request) do
      case RequestController.await(controller, timeout) do
        {:error, :timeout} = timeout_result ->
          maybe_cancel_after_timeout(request, opts)
          timeout_result

        result ->
          result
      end
    end
  end

  def await(_request, opts) when is_list(opts), do: {:error, :invalid_async_request}

  @spec cancel(Request.t(), keyword()) :: {:ok, Cancellation.t()} | {:error, term()}
  def cancel(request, opts \\ [])

  def cancel(%Request{} = request, opts) when is_list(opts) do
    with {:ok, controller} <- Request.controller(request) do
      RequestController.cancel(controller, opts)
    end
  end

  def cancel(_request, opts) when is_list(opts), do: {:error, :invalid_async_request}

  defp maybe_cancel_after_timeout(request, opts) do
    if Keyword.get(opts, :cancel_on_timeout, true) do
      _result = cancel(request, grace_ms: Keyword.get(opts, :cancel_grace_ms, 100))
    end

    :ok
  end

  defp request_id(opts) do
    case Keyword.get(opts, :request_id) do
      request_id when is_binary(request_id) and request_id != "" -> request_id
      _request_id -> Jidoka.Id.generate!("chat")
    end
  end

  defp prepare_opts(opts, request_id, caller) do
    opts
    |> Keyword.put(:request_id, request_id)
    |> maybe_put_default_stream_to(caller)
  end

  defp maybe_put_default_stream_to(opts, caller) do
    cond do
      Keyword.has_key?(opts, :stream_to) -> opts
      Keyword.get(opts, :stream) == true -> Keyword.put(opts, :stream_to, caller)
      true -> opts
    end
  end

  defp stream_to(opts) do
    case Keyword.get(opts, :stream_to) do
      pid when is_pid(pid) -> pid
      {:pid, pid} when is_pid(pid) -> pid
      _other -> nil
    end
  end

  defp metadata(opts) do
    case Keyword.get(opts, :metadata, %{}) do
      metadata when is_map(metadata) -> metadata
      _metadata -> %{}
    end
  end

  defp session_id(%Jidoka.Session.Data{session_id: session_id}), do: session_id
  defp session_id(_target), do: nil
end
