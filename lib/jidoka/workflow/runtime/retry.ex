defmodule Jidoka.Workflow.Runtime.Retry do
  @moduledoc false

  alias Jidoka.Workflow.Step

  @spec call(Step.t(), (-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def call(%Step{retry: nil}, fun), do: safe_target_call(fun)

  def call(%Step{retry: %{max_attempts: max_attempts} = retry}, fun) do
    do_call(fun, retry, max_attempts, 1)
  end

  defp do_call(_fun, _retry, max_attempts, attempt) when attempt > max_attempts do
    {:error, {:retry_exhausted, max_attempts}}
  end

  defp do_call(fun, retry, max_attempts, attempt) do
    case safe_target_call(fun) do
      {:ok, _value} = ok ->
        ok

      {:error, {:agent_hibernated, _snapshot}} = error ->
        error

      {:error, _reason} when attempt < max_attempts ->
        sleep_before_retry(retry, attempt)
        do_call(fun, retry, max_attempts, attempt + 1)

      {:error, reason} ->
        {:error, {:retry_exhausted, max_attempts, reason}}
    end
  end

  defp safe_target_call(fun) do
    fun.()
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp sleep_before_retry(%{backoff: %{min: min, max: max, type: type}}, attempt) do
    delay =
      case type do
        :exponential -> (min * :math.pow(2, attempt - 1)) |> round()
        _fixed -> min
      end

    delay
    |> cap_backoff(max)
    |> Process.sleep()
  end

  defp cap_backoff(delay, max) when max > 0, do: min(delay, max)
  defp cap_backoff(delay, _max), do: delay
end
