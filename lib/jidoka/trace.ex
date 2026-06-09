defmodule Jidoka.Trace do
  @moduledoc """
  Trace projection helpers for Jidoka runtime events.
  """

  alias Jidoka.Event
  alias Jidoka.Trace.{Policy, Sink}

  @doc "Returns the core event names projected by trace timelines."
  @spec events() :: [atom()]
  def events, do: Event.events()

  @doc "Projects core events into a compact, sequence-stable trace timeline."
  @spec timeline(list()) :: [map()]
  def timeline(events), do: timeline(events, [])

  @doc "Projects, samples, and redacts core events for trace consumers."
  @spec timeline(list(), keyword() | map()) :: [map()]
  def timeline(events, opts) when is_list(events) do
    policy = policy!(opts)

    events
    |> Enum.with_index()
    |> Enum.map(fn {event, index} -> timeline_event(event, index) end)
    |> Enum.filter(&sampled?(&1, policy))
    |> Enum.map(&redact(&1, policy))
  end

  def timeline(_events, _opts), do: []

  @doc "Records projected trace entries into a caller-provided sink."
  @spec record(list(), Sink.sink(), keyword()) :: :ok | {:error, term()}
  def record(events, sink, opts \\ []) when is_list(events) do
    with {:ok, policy} <- policy(opts) do
      Sink.record(sink, timeline(events, policy: policy), policy, opts)
    end
  end

  @doc "Redacts or omits sensitive keys from trace-shaped data."
  @spec redact(term(), Policy.t() | keyword() | map() | nil) :: term()
  def redact(value, policy \\ nil)

  def redact(value, %Policy{} = policy), do: redact_value(value, policy)

  def redact(value, policy_input) do
    case Policy.from_input(policy_input) do
      {:ok, policy} -> redact(value, policy)
      {:error, _reason} -> value
    end
  end

  defp timeline_event(%Event{} = event, _index) do
    event
    |> Event.to_map()
    |> Map.put(:projection, :trace)
  end

  defp timeline_event(%{} = event, index) do
    event
    |> Map.put_new(:seq, index)
    |> Map.put_new(:projection, :trace)
  end

  defp timeline_event(other, index) do
    %{seq: index, projection: :trace, event: :unknown_event, data: %{value: other}}
  end

  defp policy(%Policy{} = policy), do: Policy.from_input(policy)

  defp policy(opts) when is_list(opts) do
    cond do
      Keyword.has_key?(opts, :policy) ->
        Policy.from_input(Keyword.fetch!(opts, :policy))

      Keyword.has_key?(opts, :trace_policy) ->
        Policy.from_input(Keyword.fetch!(opts, :trace_policy))

      true ->
        Policy.from_input(opts)
    end
  end

  defp policy(%{} = opts) do
    cond do
      Map.has_key?(opts, :policy) ->
        Policy.from_input(Map.fetch!(opts, :policy))

      Map.has_key?(opts, "policy") ->
        Policy.from_input(Map.fetch!(opts, "policy"))

      Map.has_key?(opts, :trace_policy) ->
        Policy.from_input(Map.fetch!(opts, :trace_policy))

      Map.has_key?(opts, "trace_policy") ->
        Policy.from_input(Map.fetch!(opts, "trace_policy"))

      true ->
        Policy.from_input(opts)
    end
  end

  defp policy(_opts), do: Policy.from_input(nil)

  defp policy!(opts) do
    case policy(opts) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, "invalid trace policy: #{inspect(reason)}"
    end
  end

  defp sampled?(_entry, %Policy{enabled: false}), do: false
  defp sampled?(_entry, %Policy{sample_rate: rate}) when rate >= 1.0, do: true
  defp sampled?(_entry, %Policy{sample_rate: rate}) when rate <= 0.0, do: false

  defp sampled?(entry, %Policy{sample_rate: rate}) do
    key = {Map.get(entry, :request_id), Map.get(entry, :seq), Map.get(entry, :event)}
    :erlang.phash2(key, 1_000_000) / 1_000_000 <= rate
  end

  defp redact_value(%_{} = struct, %Policy{} = policy) do
    struct
    |> Map.from_struct()
    |> redact_value(policy)
  end

  defp redact_value(%{} = map, %Policy{} = policy) do
    Enum.reduce(map, %{}, fn {key, value}, redacted ->
      key_name = key_name(key)

      cond do
        key_name in policy.omit_keys ->
          redacted

        key_name in policy.redact_keys ->
          Map.put(redacted, key, "[REDACTED]")

        true ->
          Map.put(redacted, key, redact_value(value, policy))
      end
    end)
  end

  defp redact_value(list, %Policy{} = policy) when is_list(list) do
    Enum.map(list, &redact_value(&1, policy))
  end

  defp redact_value(value, _policy), do: value

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: key
  defp key_name(key), do: to_string(key)
end
