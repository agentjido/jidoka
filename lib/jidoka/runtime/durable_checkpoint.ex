defmodule Jidoka.Runtime.DurableCheckpoint do
  @moduledoc false

  alias Jidoka.Effect
  alias Jidoka.Turn

  @doc false
  @spec persist(Turn.State.t(), Effect.Intent.t(), atom(), keyword()) :: :ok | {:error, term()}
  def persist(%Turn.State{} = state, %Effect.Intent{} = intent, stage, opts)
      when is_atom(stage) and is_list(opts) do
    case Keyword.get(opts, :durable_checkpoint) do
      checkpoint when is_function(checkpoint, 3) ->
        checkpoint
        |> invoke(state, intent, stage)
        |> normalize_result()

      _checkpoint ->
        :ok
    end
  end

  defp invoke(checkpoint, state, intent, stage) do
    checkpoint.(state, intent, stage)
  rescue
    exception -> {:error, {:durable_checkpoint_failed, exception}}
  catch
    kind, reason -> {:error, {:durable_checkpoint_failed, {kind, reason}}}
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:ok, _stored}), do: :ok
  defp normalize_result({:error, _reason} = error), do: error
  defp normalize_result(other), do: {:error, {:invalid_durable_checkpoint_result, other}}
end
