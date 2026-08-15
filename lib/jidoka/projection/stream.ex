defmodule Jidoka.Projection.Stream do
  @moduledoc """
  Portable, redacted, bounded projection for one ordered request stream.

  This module is an implementation detail of `Jidoka.project_events/1`. Hosts
  should call the root facade, not this module.
  """

  alias Jidoka.Event
  alias Jidoka.Event.Order
  alias Jidoka.Portable

  @max_unknown_bytes 4_096
  @max_data_bytes 65_536

  @type projection :: %{
          required(:request_id) => String.t(),
          required(:seq) => non_neg_integer(),
          required(:event) => String.t(),
          required(:terminal?) => boolean(),
          optional(:agent_id) => String.t(),
          optional(:turn_id) => String.t(),
          optional(:effect_id) => String.t(),
          optional(:effect_kind) => String.t(),
          optional(:operation) => String.t(),
          optional(:loop_index) => non_neg_integer(),
          optional(:status) => String.t(),
          optional(:category) => String.t(),
          optional(:phase) => String.t(),
          optional(:data) => map(),
          optional(:error) => term(),
          optional(:unknown) => map()
        }

  @doc "Projects one event through the portable request-stream contract."
  @spec project(Event.t() | term()) :: {:ok, projection()} | {:error, term()}
  def project(%Event{} = event) do
    with :ok <- require_request(event),
         {:ok, data} <- project_data(event.data) do
      projection =
        %{
          request_id: event.request_id,
          seq: event.seq,
          event: Atom.to_string(event.event),
          terminal?: Order.terminal?(event)
        }
        |> maybe_put(:agent_id, event.agent_id)
        |> maybe_put(:turn_id, turn_id(event))
        |> maybe_put(:effect_id, event.effect_id)
        |> maybe_put(:effect_kind, stringify(event.effect_kind))
        |> maybe_put(:operation, event.operation)
        |> maybe_put(:loop_index, event.loop_index)
        |> maybe_put(:status, stringify(event.status))
        |> maybe_put(:category, stringify(event.category))
        |> maybe_put(:phase, stringify(event.phase))
        |> maybe_put(:data, data)
        |> maybe_put(:error, project_error(event.error))

      require_bounded_projection(projection)
    end
  end

  def project(value), do: {:error, {:unsupported_projection, value}}

  @doc "Projects an ordered event list."
  @spec project_events([Event.t()]) :: {:ok, [projection()]} | {:error, term()}
  def project_events(events) when is_list(events) do
    events
    |> Enum.reduce_while({:ok, []}, fn event, {:ok, acc} ->
      case project(event) do
        {:ok, projected} -> {:cont, {:ok, [projected | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      {:error, _reason} = error -> error
    end
  end

  defp require_request(%Event{request_id: request_id}) when is_binary(request_id), do: :ok
  defp require_request(%Event{}), do: {:error, :missing_request_id}

  defp project_data(data) when data in [nil, %{}], do: {:ok, nil}

  defp project_data(data) when is_map(data) do
    projected = data |> Portable.project() |> drop_runtime() |> stringify_keys()

    cond do
      encoded_size(projected) > @max_data_bytes ->
        {:error, :projection_too_large}

      true ->
        {known, unknown} = split_unknown(projected)

        if encoded_size(unknown) > @max_unknown_bytes do
          {:error, :unknown_projection_overflow}
        else
          {:ok, maybe_put(known, "unknown", empty_to_nil(unknown))}
        end
    end
  end

  defp project_data(data), do: {:ok, drop_runtime(Portable.project(data))}

  defp project_error(nil), do: nil

  defp project_error(error) do
    error
    |> Portable.project()
    |> drop_runtime()
    |> stringify_keys()
    |> json_safe()
  end

  defp json_safe(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_map(value), do: Map.new(value, fn {key, item} -> {stringify(key), json_safe(item)} end)
  defp json_safe(value), do: inspect(value)

  defp drop_runtime(value) when is_pid(value) or is_reference(value) or is_function(value) or is_port(value) do
    nil
  end

  defp drop_runtime(%module{} = struct) do
    if json_safe_struct?(module) do
      struct
    else
      struct |> Map.from_struct() |> drop_runtime()
    end
  end

  defp drop_runtime(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {key, item}, acc ->
      case drop_runtime(item) do
        nil -> acc
        projected -> Map.put(acc, key, projected)
      end
    end)
  end

  defp drop_runtime(value) when is_list(value), do: Enum.map(value, &drop_runtime/1)
  defp drop_runtime(value), do: value

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {stringify(key), stringify_keys(item)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value) when is_atom(value) and value not in [nil, true, false], do: Atom.to_string(value)
  defp stringify_keys(value), do: value

  defp split_unknown(data) do
    Enum.split_with(data, fn {key, _value} -> known_data_key?(key) end)
    |> then(fn {known, unknown} -> {Map.new(known), Map.new(unknown)} end)
  end

  defp known_data_key?(key)
       when key in ~w(
              reason forced content text operation turn_id token
              type delta chunk_type call usage warning finish_reason error
            ),
       do: true

  defp known_data_key?(_key), do: false

  defp turn_id(%Event{data: %{turn_id: turn_id}}) when is_binary(turn_id), do: turn_id
  defp turn_id(%Event{data: %{"turn_id" => turn_id}}) when is_binary(turn_id), do: turn_id
  defp turn_id(%Event{}), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, %{} = value) when map_size(value) == 0, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp empty_to_nil(value) when value == %{}, do: nil
  defp empty_to_nil(value), do: value

  defp json_safe_struct?(module) do
    module in [Date, Time, DateTime, NaiveDateTime]
  end

  defp require_bounded_projection(projection) do
    if encoded_size(projection) <= @max_data_bytes,
      do: {:ok, projection},
      else: {:error, :projection_too_large}
  end

  defp encoded_size(value) do
    case Jason.encode(value) do
      {:ok, json} -> byte_size(json)
      {:error, _reason} -> @max_data_bytes + 1
    end
  end
end
