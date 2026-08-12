defmodule Jidoka.Replay.Environment do
  @moduledoc "Recording and replay wrapper for provider-neutral execution-environment lifecycle calls."

  alias Jidoka.ExecutionEnvironment.EnforcementEvidence
  alias Jidoka.Replay.Recorder

  @actions ~w(open acquire checkpoint restore fork close cleanup execute)

  @doc "Records one environment lifecycle callback after public normalization."
  @spec record(Recorder.controller(), atom() | String.t(), term(), (-> term())) :: term()
  def record(recorder, action, request, function) when is_function(function, 0) do
    with {:ok, action} <- action(action) do
      Recorder.capture(recorder, :environment, action, request, function)
    end
  end

  @doc "Replays one environment lifecycle callback and marks enforcement evidence as recorded."
  @spec replay(Recorder.controller(), atom() | String.t(), term()) :: term()
  def replay(player, action, request) do
    with {:ok, action} <- action(action) do
      result = Recorder.capture(player, :environment, action, request, fn -> :unreachable end)

      case mark_recorded(result) do
        {:ok, result} -> result
        {:error, reason} -> {:error, {:invalid_recorded_environment_evidence, reason}}
      end
    end
  end

  defp action(action) do
    action = to_string(action)
    if action in @actions, do: {:ok, action}, else: {:error, {:invalid_environment_replay_action, action}}
  end

  defp mark_recorded(value) when is_tuple(value) do
    with {:ok, values} <- mark_list(Tuple.to_list(value)), do: {:ok, List.to_tuple(values)}
  end

  defp mark_recorded(%{} = value) do
    with {:ok, value} <- mark_map(value) do
      if evidence?(value), do: recorded_evidence(value), else: {:ok, value}
    end
  end

  defp mark_recorded(value) when is_list(value), do: mark_list(value)
  defp mark_recorded(value), do: {:ok, value}

  defp mark_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, marked} ->
      case mark_recorded(value) do
        {:ok, value} -> {:cont, {:ok, [value | marked]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end)
  end

  defp mark_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, nested}, {:ok, marked} ->
      case mark_recorded(nested) do
        {:ok, nested} -> {:cont, {:ok, Map.put(marked, key, nested)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp recorded_evidence(value) do
    with {:ok, evidence} <- EnforcementEvidence.new(value) do
      facts = Map.merge(evidence.facts, %{"evidence_source" => "recorded", "live" => false})
      {:ok, evidence |> Map.put(:facts, facts) |> EnforcementEvidence.to_map()}
    end
  end

  defp evidence?(value) do
    has_key?(value, :status) and has_key?(value, :adapter_id) and has_key?(value, :backend) and
      has_key?(value, :observed_at_ms)
  end

  defp has_key?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
end
