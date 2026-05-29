defmodule Jidoka.Runtime.EffectInterpreter do
  @moduledoc """
  Effect shell for the functional core.

  The interpreter records an intent before calling a runtime capability and
  never calls that capability when the journal already has a result for the same
  effect id.
  """

  alias Jidoka.Error
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Effect
  alias Jidoka.Turn

  @spec interpret_pending(Turn.State.t(), Capabilities.t()) ::
          {:ok, Effect.Result.t(), Turn.State.t()} | {:error, term()}
  def interpret_pending(
        %Turn.State{pending_effect: %Effect.Intent{} = intent} = state,
        %Capabilities{} = capabilities
      ) do
    case Effect.Journal.result_for(state.journal, intent) do
      %Effect.Result{} = result ->
        {:ok, result, state}

      nil ->
        journal = Effect.Journal.put_intent(state.journal, intent)

        with {:ok, result} <- call_capability(intent, capabilities, journal) do
          journal = Effect.Journal.put_result(journal, result)
          {:ok, result, %Turn.State{state | journal: journal}}
        end
    end
  end

  def interpret_pending(_state, _capabilities) do
    {:error,
     Error.normalize(:missing_pending_effect, operation: :interpret_effect, phase: :effect)}
  end

  defp call_capability(%Effect.Intent{kind: :llm} = intent, %Capabilities{llm: llm}, journal) do
    case invoke_capability(llm, intent, journal) do
      {:ok, output} ->
        {:ok, Effect.Result.ok(intent, output)}

      {:error, reason} ->
        {:ok, Effect.Result.error(intent, normalize_capability_error(reason, intent))}

      other ->
        {:ok,
         Effect.Result.error(
           intent,
           normalize_capability_error({:invalid_capability_result, other}, intent)
         )}
    end
  end

  defp call_capability(
         %Effect.Intent{kind: :operation} = intent,
         %Capabilities{operations: operations},
         journal
       ) do
    case invoke_capability(operations, intent, journal) do
      {:ok, output} ->
        {:ok, Effect.Result.ok(intent, output)}

      {:error, reason} ->
        {:ok, Effect.Result.error(intent, normalize_capability_error(reason, intent))}

      other ->
        {:ok,
         Effect.Result.error(
           intent,
           normalize_capability_error({:invalid_capability_result, other}, intent)
         )}
    end
  end

  defp invoke_capability(capability, intent, journal) do
    capability.(intent, journal)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_capability_error(reason, %Effect.Intent{} = intent) do
    Error.normalize(reason,
      operation: intent.kind,
      phase: :effect,
      intent_id: intent.id,
      effect_kind: intent.kind
    )
  end
end
