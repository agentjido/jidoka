defmodule Jidoka.Chat.Request do
  @moduledoc """
  Runtime handle for an async Jidoka chat request.

  The handle is intentionally not part of the durable agent data contract. It is
  a caller-owned runtime convenience for UI processes that need to start a turn,
  stream request-scoped events, and await the normalized final chat result.
  """

  alias Jidoka.Cancellation
  alias Jidoka.Chat
  alias Jidoka.Chat.RequestController

  @type t :: %__MODULE__{
          request_id: String.t(),
          task: Task.t(),
          controller: pid() | nil,
          cancellation: Cancellation.token() | nil,
          target: term(),
          session_id: String.t() | nil,
          stream_to: pid() | nil,
          started_at_ms: integer(),
          metadata: map()
        }

  @schema Zoi.struct(
            __MODULE__,
            %{
              request_id: Zoi.string(),
              task: Zoi.any(),
              controller: Zoi.any() |> Zoi.nullish(),
              cancellation: Zoi.any() |> Zoi.nullish(),
              target: Zoi.any(),
              session_id: Zoi.string() |> Zoi.nullish(),
              stream_to: Zoi.any() |> Zoi.nullish(),
              started_at_ms: Zoi.integer(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc false
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs), do: struct!(__MODULE__, attrs)

  @doc "Starts an async chat task and returns a request handle."
  @spec start(term(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(target, input, opts) when is_binary(input) and is_list(opts) do
    start_fun(target, input, opts, fn prepared_opts ->
      Chat.run(target, input, prepared_opts)
    end)
  end

  @doc false
  @spec start_fun(term(), String.t(), keyword(), (keyword() -> term())) :: {:ok, t()} | {:error, term()}
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
         {:ok, task, cancellation} <- RequestController.runtime(controller) do
      {:ok,
       new(
         request_id: request_id,
         task: task,
         controller: controller,
         cancellation: cancellation,
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

  @doc "Waits for an async chat request to finish."
  @spec await(t(), keyword()) :: term() | {:cancelled, Cancellation.t()} | {:error, term()}
  def await(request, opts \\ [])

  def await(%__MODULE__{controller: controller} = request, opts)
      when is_pid(controller) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    case RequestController.await(controller, timeout) do
      {:error, :timeout} = timeout_result ->
        maybe_cancel_after_timeout(request, opts)
        timeout_result

      result ->
        result
    end
  end

  def await(%__MODULE__{task: %Task{} = task}, opts) when is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    case Task.yield(task, timeout) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:chat_request_failed, reason}}
      nil -> timeout_result(task, opts)
    end
  end

  @doc "Cancels an active async chat request and waits for bounded cleanup."
  @spec cancel(t(), keyword()) :: {:ok, Cancellation.t()} | {:error, term()}
  def cancel(request, opts \\ [])

  def cancel(%__MODULE__{controller: controller}, opts)
      when is_pid(controller) and is_list(opts) do
    RequestController.cancel(controller, opts)
  end

  def cancel(%__MODULE__{task: %Task{} = task, request_id: request_id}, _opts) do
    _shutdown = Task.shutdown(task, :brutal_kill)

    {:ok,
     Cancellation.new!(
       request_id: request_id,
       forced?: true,
       cancelled_at_ms: System.system_time(:millisecond)
     )}
  end

  defp timeout_result(%Task{} = task, opts) do
    if Keyword.get(opts, :cancel_on_timeout, true) do
      Task.shutdown(task, :brutal_kill)
    end

    {:error, :timeout}
  end

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
      Keyword.has_key?(opts, :stream_to) ->
        opts

      Keyword.get(opts, :stream) == true ->
        Keyword.put(opts, :stream_to, caller)

      true ->
        opts
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
    opts
    |> Keyword.get(:metadata, %{})
    |> case do
      metadata when is_map(metadata) -> metadata
      _metadata -> %{}
    end
  end

  defp session_id(%Jidoka.Session.Data{session_id: session_id}), do: session_id
  defp session_id(_target), do: nil
end
