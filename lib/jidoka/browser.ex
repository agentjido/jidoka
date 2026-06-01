defmodule Jidoka.Browser do
  @moduledoc """
  Constrained browser tool source backed by `jido_browser` actions.

  Jidoka keeps this surface read-only. The DSL exposes search/page-read
  capabilities as normal Jido action modules, while this module owns source
  selection and shared runtime policy.
  """

  @type mode :: :search | :read_only

  @doc "Returns the Jido action modules exposed for a browser mode."
  @spec tool_modules(mode() | String.t()) :: [module()]
  def tool_modules(mode) do
    case normalize_mode(mode) do
      {:ok, :search} -> search_tools()
      {:ok, :read_only} -> read_only_tools()
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc "Normalizes browser DSL mode values into the runtime mode enum."
  @spec normalize_mode(term()) :: {:ok, mode()} | {:error, String.t()}
  def normalize_mode(mode) when mode in [:search, :read_only], do: {:ok, mode}

  def normalize_mode(mode) when is_binary(mode) do
    mode
    |> String.trim()
    |> case do
      "search" -> {:ok, :search}
      "read_only" -> {:ok, :read_only}
      other -> {:error, invalid_mode_message(other)}
    end
  end

  def normalize_mode(mode), do: {:error, invalid_mode_message(mode)}

  defp invalid_mode_message(mode) do
    "browser mode must be :search or :read_only, got: #{inspect(mode)}"
  end

  defp search_tools do
    [Module.concat([Jidoka, Browser, Tools, SearchWeb])]
  end

  defp read_only_tools do
    [
      Module.concat([Jidoka, Browser, Tools, SearchWeb]),
      Module.concat([Jidoka, Browser, Tools, ReadPage]),
      Module.concat([Jidoka, Browser, Tools, SnapshotUrl])
    ]
  end
end
