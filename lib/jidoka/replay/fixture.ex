defmodule Jidoka.Replay.Fixture.Entry do
  @moduledoc "One ordered portable capability exchange in a replay fixture."

  @enforce_keys [:index, :class, :action, :fingerprint, :occurrence, :outcome, :response]
  defstruct [:index, :class, :action, :fingerprint, :occurrence, :outcome, :response, evidence: %{}]

  @type t :: %__MODULE__{
          index: pos_integer(),
          class: String.t(),
          action: String.t(),
          fingerprint: String.t(),
          occurrence: pos_integer(),
          outcome: String.t(),
          response: term(),
          evidence: map()
        }

  @classes ~w(llm operation policy environment)
  @outcomes ~w(ok error)

  alias Jidoka.Replay.Codec

  @doc "Builds and validates one fixture entry."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    entry = %__MODULE__{
      index: value(attrs, :index),
      class: value(attrs, :class),
      action: value(attrs, :action),
      fingerprint: value(attrs, :fingerprint),
      occurrence: value(attrs, :occurrence),
      outcome: value(attrs, :outcome),
      response: value(attrs, :response),
      evidence: value(attrs, :evidence, %{})
    }

    with true <- is_integer(entry.index) and entry.index > 0,
         true <- entry.class in @classes,
         true <- is_binary(entry.action) and entry.action != "" and byte_size(entry.action) <= 128,
         :ok <- Jidoka.ExecutionEnvironment.Contract.validate_digest(entry.fingerprint, []),
         true <- is_integer(entry.occurrence) and entry.occurrence > 0,
         true <- entry.outcome in @outcomes,
         :ok <- Jidoka.ExecutionEnvironment.Contract.validate_portable(entry.response),
         {:ok, decoded} <- Codec.decode(entry.response),
         {:ok, canonical} <- Codec.encode(decoded),
         true <- canonical == entry.response,
         :ok <- Jidoka.ExecutionEnvironment.Contract.validate_safe_map(entry.evidence) do
      {:ok, entry}
    else
      false -> {:error, {:invalid_fixture_entry, attrs}}
      {:error, reason} -> {:error, {:invalid_fixture_entry, reason}}
    end
  end

  def new(attrs), do: {:error, {:invalid_fixture_entry, attrs}}

  @doc "Projects an entry to JSON-safe data."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = entry),
    do: entry |> Map.from_struct() |> Map.new(fn {key, value} -> {to_string(key), value} end)

  defp value(map, key, default \\ nil), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end

defmodule Jidoka.Replay.Fixture do
  @moduledoc "Versioned, portable, and redacted capability replay data."

  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.Replay.Codec
  alias Jidoka.Replay.Fixture.Entry

  @version 1
  @enforce_keys [:version, :compatibility, :entries, :redaction, :digest]
  defstruct [:version, :compatibility, :entries, :redaction, :digest]

  @type t :: %__MODULE__{
          version: pos_integer(),
          compatibility: map(),
          entries: [Entry.t()],
          redaction: map(),
          digest: String.t()
        }

  @doc "Returns the fixture schema version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Builds and verifies a fixture. An omitted digest is calculated."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    with @version <- value(attrs, :version, @version),
         compatibility when is_map(compatibility) <- value(attrs, :compatibility, %{}),
         :ok <- Contract.validate_safe_map(compatibility),
         {:ok, entries} <- entries(value(attrs, :entries, [])),
         :ok <- validate_order(entries),
         redaction when is_map(redaction) <- value(attrs, :redaction, default_redaction()),
         :ok <- Contract.validate_safe_map(redaction) do
      calculated = calculate_digest(compatibility, entries, redaction)

      case value(attrs, :digest) do
        nil -> {:ok, build(compatibility, entries, redaction, calculated)}
        ^calculated -> {:ok, build(compatibility, entries, redaction, calculated)}
        supplied -> {:error, {:fixture_digest_mismatch, calculated, supplied}}
      end
    else
      version when is_integer(version) -> {:error, {:unsupported_fixture_version, version, @version}}
      {:error, reason} -> {:error, reason}
      invalid -> {:error, {:invalid_capability_fixture, invalid}}
    end
  end

  def new(attrs), do: {:error, {:invalid_capability_fixture, attrs}}

  @doc "Returns the verified stable digest."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{digest: digest}), do: digest

  @doc "Projects a fixture to JSON-safe data."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = fixture) do
    %{
      "version" => fixture.version,
      "compatibility" => fixture.compatibility,
      "entries" => Enum.map(fixture.entries, &Entry.to_map/1),
      "redaction" => fixture.redaction,
      "digest" => fixture.digest
    }
  end

  @doc "Encodes a verified fixture as JSON."
  @spec encode_json(t()) :: {:ok, String.t()} | {:error, term()}
  def encode_json(%__MODULE__{} = fixture), do: Jason.encode(to_map(fixture))

  @doc "Decodes and verifies one JSON fixture."
  @spec decode_json(String.t()) :: {:ok, t()} | {:error, term()}
  def decode_json(json) when is_binary(json) do
    with {:ok, attrs} <- Jason.decode(json), do: new(attrs)
  end

  defp entries(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, entries} ->
      case Entry.new(value) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end)
  end

  defp entries(value), do: {:error, {:invalid_fixture_entries, value}}

  defp validate_order(entries) do
    indexes = Enum.map(entries, & &1.index)
    keys = Enum.map(entries, &{&1.class, &1.action, &1.fingerprint, &1.occurrence})
    expected_indexes = if entries == [], do: [], else: Enum.to_list(1..length(entries))

    cond do
      indexes != expected_indexes -> {:error, {:invalid_fixture_order, indexes}}
      Enum.uniq(keys) != keys -> {:error, :duplicate_fixture_entry}
      true -> :ok
    end
  end

  defp calculate_digest(compatibility, entries, redaction) do
    Codec.digest(%{
      "version" => @version,
      "compatibility" => compatibility,
      "entries" => Enum.map(entries, &Entry.to_map/1),
      "redaction" => redaction
    })
  end

  defp build(compatibility, entries, redaction, digest) do
    %__MODULE__{
      version: @version,
      compatibility: compatibility,
      entries: entries,
      redaction: redaction,
      digest: digest
    }
  end

  defp default_redaction do
    %{"key_filter" => "sensitive", "request_bodies" => "fingerprint_only", "live_values" => "rejected"}
  end

  defp value(map, key, default \\ nil), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
