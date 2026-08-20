defmodule Jidoka.Session.Sequence.Async do
  @moduledoc false

  alias Jidoka.Cancellation
  alias Jidoka.Session.Data
  alias Jidoka.Session.Sequence
  alias Jidoka.Session.Sequence.Request
  alias Jidoka.Session.Sequence.RequestController

  @type await_result ::
          {:ok, Sequence.Result.t()}
          | {:cancelled, Cancellation.t(), Sequence.Result.t()}
          | {:error, term()}

  @doc false
  @spec start(Data.t() | String.t(), Data.t(), Sequence.input(), keyword()) ::
          {:ok, Request.t()} | {:error, term()}
  def start(session_input, %Data{} = session, request_inputs, opts)
      when is_list(request_inputs) and is_list(opts) do
    request_id = request_id(opts)
    caller = self()

    with {:ok, controller} <-
           RequestController.start(
             request_id: request_id,
             owner: caller,
             session_input: session_input,
             session: session,
             request_inputs: request_inputs,
             runtime_opts: opts
           ) do
      request =
        Request.new(
          request_id: request_id,
          controller: controller,
          session_id: session.session_id,
          started_at_ms: System.system_time(:millisecond),
          metadata: metadata(opts)
        )

      with :ok <- RequestController.ready(controller), do: {:ok, request}
    end
  rescue
    exception -> {:error, exception}
  end

  @doc false
  @spec await(term(), keyword()) :: await_result()
  def await(request, opts \\ []) when is_list(opts) do
    with {:ok, controller} <- Request.controller(request) do
      timeout = Keyword.get(opts, :timeout, 30_000)

      case RequestController.await(controller, timeout) do
        {:error, :timeout} = timeout_result ->
          maybe_cancel_after_timeout(request, opts)
          timeout_result

        result ->
          result
      end
    end
  end

  @doc false
  @spec cancel(term(), keyword()) :: {:ok, Cancellation.t()} | {:error, term()}
  def cancel(request, opts \\ []) when is_list(opts) do
    with {:ok, controller} <- Request.controller(request) do
      RequestController.cancel(controller, opts)
    end
  end

  defp maybe_cancel_after_timeout(request, opts) do
    if Keyword.get(opts, :cancel_on_timeout, true) do
      _result = cancel(request, grace_ms: Keyword.get(opts, :cancel_grace_ms, 100))
    end

    :ok
  end

  defp request_id(opts) do
    case Keyword.get(opts, :sequence_request_id) do
      request_id when is_binary(request_id) and request_id != "" -> request_id
      _request_id -> Jidoka.Id.generate!("sequence")
    end
  end

  defp metadata(opts) do
    case Keyword.get(opts, :sequence_metadata, %{}) do
      metadata when is_map(metadata) -> metadata
      _metadata -> %{}
    end
  end
end
