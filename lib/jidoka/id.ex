defmodule Jidoka.Id do
  @moduledoc """
  Small boundary for generated Jidoka identifiers.

  Core data constructors accept explicit IDs. When callers use convenience
  constructors without IDs, generation is routed through this module so entropy
  is isolated and tests can inject deterministic generators.
  """

  @type prefix :: String.t()
  @type generator :: (prefix() -> String.t())

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

  @spec generate!(prefix(), generator() | nil) :: String.t()
  def generate!(prefix, generator \\ nil) do
    case generate(prefix, generator) do
      {:ok, id} -> id
      {:error, reason} -> raise ArgumentError, "invalid generated id: #{inspect(reason)}"
    end
  end

  @spec random(prefix()) :: String.t()
  def random(prefix) when is_binary(prefix) do
    prefix <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
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
end
