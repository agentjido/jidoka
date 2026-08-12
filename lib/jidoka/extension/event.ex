defmodule Jidoka.Extension.Event do
  @moduledoc "Versioned portable lifecycle event for trusted extensions."

  alias Jidoka.ExecutionEnvironment.Contract

  @version 1
  @max_payload_bytes 65_536
  @events ~w(
    session.start session.resume session.compact session.end
    turn.start turn.update turn.end
    model.start model.update model.end model.error
    tool.before tool.update tool.after tool.error
    automation.cell.start automation.cell.end
  )
  @enforce_keys [:event_id, :name, :timestamp_ms, :data]
  defstruct version: @version,
            event_id: nil,
            name: nil,
            timestamp_ms: nil,
            session_ref: nil,
            request_ref: nil,
            turn_ref: nil,
            extension_namespace: nil,
            data: %{}

  @type t :: %__MODULE__{
          version: 1,
          event_id: String.t(),
          name: String.t(),
          timestamp_ms: non_neg_integer(),
          session_ref: String.t() | nil,
          request_ref: String.t() | nil,
          turn_ref: String.t() | nil,
          extension_namespace: String.t() | nil,
          data: map()
        }

  @doc "Returns the fixed protocol-v1 event catalog."
  @spec names() :: [String.t()]
  def names, do: @events

  @doc "Builds a portable event. IDs and time can be injected for tests."
  @spec new(keyword() | map(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs, opts \\ []) do
    attrs = Jidoka.Schema.normalize_attrs(attrs)
    data = attrs |> Jidoka.Schema.get_key(:data, %{}) |> Contract.project()

    event = %__MODULE__{
      version: Jidoka.Schema.get_key(attrs, :version, @version),
      event_id: Jidoka.Schema.get_key(attrs, :event_id) || generate_id(opts),
      name: Jidoka.Schema.get_key(attrs, :name),
      timestamp_ms: Jidoka.Schema.get_key(attrs, :timestamp_ms, clock_ms(opts)),
      session_ref: Jidoka.Schema.get_key(attrs, :session_ref),
      request_ref: Jidoka.Schema.get_key(attrs, :request_ref),
      turn_ref: Jidoka.Schema.get_key(attrs, :turn_ref),
      extension_namespace: Jidoka.Schema.get_key(attrs, :extension_namespace),
      data: data
    }

    with true <- event.version == @version,
         true <- nonempty?(event.event_id),
         true <- event.name in @events,
         true <- is_integer(event.timestamp_ms) and event.timestamp_ms >= 0,
         true <- valid_refs?(event),
         true <- is_map(data),
         :ok <- Contract.validate_portable(data),
         {:ok, encoded} <- Jason.encode(to_map(event)),
         true <- byte_size(encoded) <= @max_payload_bytes do
      {:ok, event}
    else
      reason -> {:error, {:invalid_extension_event, reason}}
    end
  end

  @doc "Builds a portable event or raises."
  @spec new!(keyword() | map(), keyword()) :: t()
  def new!(attrs, opts \\ []) do
    case new(attrs, opts) do
      {:ok, event} -> event
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  @doc "Projects the event as string-key JSON data."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    event
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), Contract.project(value)} end)
  end

  defp valid_refs?(event) do
    Enum.all?(
      [event.session_ref, event.request_ref, event.turn_ref, event.extension_namespace],
      &(is_nil(&1) or nonempty?(&1))
    )
  end

  defp nonempty?(value), do: is_binary(value) and value != ""

  defp generate_id(opts) do
    case Keyword.get(opts, :id_generator) do
      generator when is_function(generator, 0) -> generator.()
      _generator -> "extension-event-#{System.unique_integer([:positive, :monotonic])}"
    end
  end

  defp clock_ms(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _clock -> System.system_time(:millisecond)
    end
  end
end
