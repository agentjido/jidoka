defmodule Jidoka.Runtime.OperationInvoker do
  @moduledoc false

  alias Jidoka.Effect
  alias Jidoka.Effect.OperationFailure
  alias Jidoka.Error
  alias Jidoka.Operation.Continuation
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.CapabilityInvoker
  alias Jidoka.Runtime.Context, as: RuntimeContext
  alias Jidoka.Turn

  @retry_safe_idempotencies [:pure, :idempotent, :dedupe]

  @doc false
  @spec invoke(Turn.State.t(), Effect.Intent.t(), Capabilities.t(), Effect.Journal.t(), keyword()) ::
          {:ok, Effect.Result.t()} | {:hibernate, Continuation.t()}
  def invoke(
        %Turn.State{} = state,
        %Effect.Intent{kind: :operation} = intent,
        %Capabilities{operations: operations},
        %Effect.Journal{} = journal,
        opts
      ) do
    with {:ok, retry} <- retry_config(opts),
         {:ok, ctx} <- RuntimeContext.operation(state, intent, opts) do
      invocation = %{
        operations: operations,
        intent: intent,
        journal: journal,
        context: ctx,
        state: state,
        retry: retry,
        opts: opts
      }

      do_invoke(invocation, 1, [])
    else
      {:error, reason} -> preflight_error_result(intent, OperationFailure.runtime(reason))
    end
  end

  defp do_invoke(invocation, attempt, attempts) do
    result =
      CapabilityInvoker.invoke(
        invocation.operations,
        invocation.intent,
        invocation.journal,
        invocation.context,
        invocation.state,
        invocation.opts
      )

    case result do
      {:ok, output} ->
        attempts = attempts ++ [%{attempt: attempt, status: :ok}]
        {:ok, Effect.Result.ok(invocation.intent, output, metadata: result_metadata(attempts))}

      {:hibernate, %Continuation{} = continuation} ->
        {:hibernate, continuation}

      {:error, reason} ->
        handle_failure(invocation, attempt, attempts, OperationFailure.classify(reason))

      other ->
        failure = OperationFailure.runtime({:invalid_capability_result, other})
        terminal_result(invocation.intent, failure, attempts, attempt)
    end
  end

  defp handle_failure(invocation, attempt, attempts, failure) do
    attempts = attempts ++ [attempt_record(attempt, failure)]

    cond do
      OperationFailure.model_visible?(failure) ->
        metadata = result_metadata(attempts, failure)
        {:ok, Effect.Result.ok(invocation.intent, OperationFailure.to_observation(failure), metadata: metadata)}

      retry?(failure, invocation.intent, attempt, invocation.retry.max_attempts) ->
        sleep(invocation.retry.backoff_ms, invocation.opts)
        do_invoke(invocation, attempt + 1, attempts)

      true ->
        terminal_result(invocation.intent, failure, attempts, attempt)
    end
  end

  defp terminal_result(intent, failure, attempts, attempt) do
    attempts = if attempts == [], do: [attempt_record(attempt, failure)], else: attempts
    error = normalize_failure(failure, intent, length(attempts))
    {:ok, Effect.Result.error(intent, error, metadata: result_metadata(attempts, failure))}
  end

  defp preflight_error_result(intent, failure) do
    error = normalize_failure(failure, intent, 0)
    metadata = result_metadata([], failure)
    {:ok, Effect.Result.error(intent, error, metadata: metadata)}
  end

  defp normalize_failure(%OperationFailure{kind: :cancelled}, intent, _attempts) do
    normalize_error(:cancelled, intent)
  end

  defp normalize_failure(%OperationFailure{reason: reason}, intent, _attempts),
    do: normalize_error(reason, intent)

  defp normalize_error(reason, intent) do
    Error.normalize(reason,
      operation: operation(intent),
      phase: :effect,
      intent_id: intent.id,
      effect_kind: intent.kind
    )
  end

  defp retry?(failure, intent, attempt, max_attempts) do
    OperationFailure.retryable?(failure) and
      intent.idempotency in @retry_safe_idempotencies and
      attempt < max_attempts
  end

  defp attempt_record(attempt, failure) do
    %{attempt: attempt, status: :error, failure: OperationFailure.to_map(failure)}
  end

  defp result_metadata(attempts, failure \\ nil) do
    %{operation_attempts: attempts, operation_attempt_count: length(attempts)}
    |> maybe_put_failure(failure)
  end

  defp maybe_put_failure(metadata, nil), do: metadata

  defp maybe_put_failure(metadata, failure),
    do: Map.put(metadata, :operation_failure, OperationFailure.to_map(failure))

  defp retry_config(opts) do
    case Keyword.get(opts, :operation_retry, []) do
      false -> {:ok, %{max_attempts: 1, backoff_ms: 0}}
      nil -> {:ok, %{max_attempts: 1, backoff_ms: 0}}
      retry when is_list(retry) -> validate_retry_config(Map.new(retry))
      retry when is_map(retry) -> validate_retry_config(retry)
      retry -> {:error, {:invalid_operation_retry, retry}}
    end
  end

  defp validate_retry_config(retry) do
    max_attempts = Map.get(retry, :max_attempts, Map.get(retry, "max_attempts", 1))
    backoff_ms = Map.get(retry, :backoff_ms, Map.get(retry, "backoff_ms", 0))

    if is_integer(max_attempts) and max_attempts >= 1 and is_integer(backoff_ms) and backoff_ms >= 0 do
      {:ok, %{max_attempts: max_attempts, backoff_ms: backoff_ms}}
    else
      {:error, {:invalid_operation_retry, retry}}
    end
  end

  defp sleep(0, _opts), do: :ok

  defp sleep(delay_ms, opts) do
    case Keyword.get(opts, :operation_retry_sleep) do
      sleep when is_function(sleep, 1) -> sleep.(delay_ms)
      _sleep -> Process.sleep(delay_ms)
    end
  end

  defp operation(%Effect.Intent{payload: payload}),
    do: Map.get(payload, :name) || Map.get(payload, "name")
end
