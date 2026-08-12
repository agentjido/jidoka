defmodule Jidoka.Replay.Capabilities do
  @moduledoc "Recording and replay wrappers for public Jidoka runtime capabilities."

  alias Jidoka.Context
  alias Jidoka.Effect
  alias Jidoka.Policy
  alias Jidoka.Replay.Recorder
  alias Jidoka.Runtime.Capabilities

  @doc "Wraps a live capability bundle and records normalized exchanges."
  @spec record(Capabilities.t(), Recorder.controller()) :: Capabilities.t()
  def record(%Capabilities{} = capabilities, recorder) do
    Capabilities.new!(
      llm: fn %Effect.Intent{} = intent, journal, %Context{} = context ->
        request = request_data(intent, context)
        Recorder.capture(recorder, :llm, :invoke, request, fn -> capabilities.llm.(intent, journal, context) end)
      end,
      operations: fn %Effect.Intent{} = intent, journal, %Context{} = context ->
        action = operation_name(intent)
        request = request_data(intent, context)

        Recorder.capture(recorder, :operation, action, request, fn ->
          capabilities.operations.(intent, journal, context)
        end)
      end,
      policy: fn %Policy.Request{} = request, %Context{} = context ->
        Recorder.capture(recorder, :policy, request.action, policy_data(request, context), fn ->
          capabilities.policy.(request, context)
        end)
      end
    )
  end

  @doc "Builds a capability bundle that can only use the replay player."
  @spec replay(Recorder.controller()) :: Capabilities.t()
  def replay(player) do
    Capabilities.new!(
      llm: fn %Effect.Intent{} = intent, _journal, %Context{} = context ->
        Recorder.capture(player, :llm, :invoke, request_data(intent, context), fn -> :unreachable end)
      end,
      operations: fn %Effect.Intent{} = intent, _journal, %Context{} = context ->
        Recorder.capture(player, :operation, operation_name(intent), request_data(intent, context), fn ->
          :unreachable
        end)
      end,
      policy: fn %Policy.Request{} = request, %Context{} = context ->
        Recorder.capture(player, :policy, request.action, policy_data(request, context), fn -> :unreachable end)
      end
    )
  end

  defp request_data(intent, context) do
    %{
      "intent" => %{
        "kind" => intent.kind,
        "payload" => semantic_data(intent.payload),
        "idempotency" => intent.idempotency
      },
      "context" => semantic_data(Context.data(context))
    }
  end

  defp policy_data(request, context) do
    request =
      request
      |> Map.from_struct()
      |> Map.drop([:session_id, :request_id, :intent_id])
      |> semantic_data()

    %{"request" => request, "context" => semantic_data(Context.data(context))}
  end

  defp operation_name(%Effect.Intent{payload: payload}) do
    to_string(Map.get(payload, :name, Map.get(payload, "name", "operation")))
  end

  defp semantic_data(%_{} = value), do: value |> Map.from_struct() |> semantic_data()

  defp semantic_data(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, _value} -> volatile_key?(key) end)
    |> Map.new(fn {key, nested} -> {key, semantic_data(nested)} end)
  end

  defp semantic_data(value) when is_list(value), do: Enum.map(value, &semantic_data/1)
  defp semantic_data(value), do: value

  defp volatile_key?(key), do: to_string(key) in ~w(run_id cell_id session_id request_id intent_id effect_id)
end
