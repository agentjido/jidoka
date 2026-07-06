defmodule Jidoka.Id do
  @moduledoc """
  Small boundary for generated Jidoka identifiers.

  Core data constructors accept explicit IDs. When callers use convenience
  constructors without IDs, generation is routed through this module so entropy
  is isolated and tests can inject deterministic generators.
  """

  @type prefix :: String.t()
  @type generator :: (prefix() -> String.t())

  @max_unix_ts_ms 0xFFFFFFFFFFFF

  @doc "Generates an ID for a prefix using either the default generator or a caller-supplied generator."
  @spec generate(prefix(), generator() | nil) :: {:ok, String.t()} | {:error, term()}
  def generate(prefix, generator \\ nil)

  def generate(prefix, nil) when is_binary(prefix) do
    {:ok, random(prefix)}
  end

  def generate(prefix, generator) when is_binary(prefix) and is_function(generator, 1) do
    prefix
    |> invoke_generator(generator)
    |> normalize_generated_id(prefix)
  end

  def generate(prefix, generator), do: {:error, {:invalid_id_generator, prefix, generator}}

  @doc "Generates an ID or raises when the generator returns an invalid value."
  @spec generate!(prefix(), generator() | nil) :: String.t()
  def generate!(prefix, generator \\ nil) do
    case generate(prefix, generator) do
      {:ok, id} -> id
      {:error, reason} -> raise ArgumentError, "invalid generated id: #{inspect(reason)}"
    end
  end

  @doc "Generates a prefixed UUIDv7 identifier."
  @spec random(prefix()) :: String.t()
  def random(prefix) when is_binary(prefix) do
    prefix <> "_" <> uuid7()
  end

  @doc "Generates a UUIDv7 identifier."
  @spec uuid7() :: String.t()
  def uuid7 do
    uuid7(System.system_time(:millisecond), :crypto.strong_rand_bytes(10))
  end

  @doc false
  @spec uuid7(non_neg_integer(), <<_::80>>) :: String.t()
  def uuid7(timestamp_ms, random_bytes)
      when is_integer(timestamp_ms) and timestamp_ms in 0..@max_unix_ts_ms and
             byte_size(random_bytes) == 10 do
    # UUIDv7 has 74 random bits; 10 random bytes provide those bits plus 6 discarded bits.
    <<rand_a::12, rand_b::62, _unused::6>> = random_bytes

    <<timestamp_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>
    |> Base.encode16(case: :lower)
    |> format_uuid()
  end

  defp invoke_generator(prefix, generator) do
    {:ok, generator.(prefix)}
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_generated_id({:ok, id}, _prefix) when is_binary(id) and id != "", do: {:ok, id}

  defp normalize_generated_id({:ok, other}, prefix),
    do: {:error, {:invalid_generated_id, prefix, other}}

  defp normalize_generated_id({:error, reason}, prefix),
    do: {:error, {:id_generator_failed, prefix, reason}}

  defp format_uuid(<<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary-size(12)>>) do
    a <> "-" <> b <> "-" <> c <> "-" <> d <> "-" <> e
  end
end
