defmodule Jidoka.Web do
  @moduledoc """
  Low-risk web capability for Jidoka agents.

  `Jidoka.Web` intentionally exposes a small, read-only subset of
  `jido_browser`: search, page reading, and page snapshots. It does not expose
  click, type, JavaScript evaluation, session state, tabs, or arbitrary browser
  control through the public Jidoka DSL.
  """

  @type mode :: :search | :read_only

  @type t :: %__MODULE__{
          mode: mode(),
          tools: [module()]
        }

  @enforce_keys [:mode, :tools]
  defstruct [:mode, :tools]

  @modes [:search, :read_only]
  @search_tools [Jidoka.Web.Tools.SearchWeb]
  @read_only_tools [
    Jidoka.Web.Tools.SearchWeb,
    Jidoka.Web.Tools.ReadPage,
    Jidoka.Web.Tools.SnapshotUrl
  ]

  @doc """
  Returns the supported web capability modes.
  """
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc """
  Returns the default maximum search results exposed to agent tools.
  """
  @spec max_results() :: pos_integer()
  defdelegate max_results, to: Jidoka.Web.Config

  @doc """
  Returns the default maximum extracted page content characters.
  """
  @spec max_content_chars() :: pos_integer()
  defdelegate max_content_chars, to: Jidoka.Web.Config

  @doc """
  Builds a web capability config.
  """
  @spec new(term()) :: {:ok, t()} | {:error, String.t()}
  def new(mode) do
    with {:ok, normalized_mode} <- normalize_mode(mode) do
      {:ok, %__MODULE__{mode: normalized_mode, tools: tools_for(normalized_mode)}}
    end
  end

  @doc false
  @spec normalize_dsl([struct()]) :: {:ok, [t()]} | {:error, String.t()}
  def normalize_dsl(entries) when is_list(entries) do
    entries
    |> Enum.map(& &1.mode)
    |> normalize_entries()
  end

  @doc false
  @spec normalize_imported([term()]) :: {:ok, [t()]} | {:error, String.t()}
  def normalize_imported(entries) when is_list(entries) do
    entries
    |> Enum.map(&imported_mode/1)
    |> normalize_entries()
  end

  def normalize_imported(other),
    do: {:error, "web capabilities must be a list, got: #{inspect(other)}"}

  @doc false
  @spec normalize_imported_specs([term()]) :: [map()]
  def normalize_imported_specs(entries) when is_list(entries) do
    Enum.map(entries, fn
      entry when is_binary(entry) -> %{mode: entry}
      %{mode: _mode} = entry -> entry
      %{"mode" => _mode} = entry -> entry
      entry -> %{mode: entry}
    end)
  end

  @doc """
  Returns all tool modules for a list of web capabilities.
  """
  @spec tool_modules([t()]) :: [module()]
  def tool_modules(web_capabilities) when is_list(web_capabilities) do
    web_capabilities
    |> Enum.flat_map(& &1.tools)
    |> Enum.uniq()
  end

  @doc """
  Returns published tool names for web capabilities.
  """
  @spec tool_names([t()]) :: {:ok, [String.t()]} | {:error, String.t()}
  def tool_names(web_capabilities) when is_list(web_capabilities) do
    web_capabilities
    |> tool_modules()
    |> Jidoka.Action.Adapter.tool_names()
  end

  @doc false
  @spec clamp_search_results(term()) :: pos_integer()
  defdelegate clamp_search_results(value), to: Jidoka.Web.Runtime

  @doc false
  @spec clamp_content_chars(term()) :: pos_integer()
  defdelegate clamp_content_chars(value), to: Jidoka.Web.Runtime

  @doc false
  @spec truncate_content(map(), pos_integer()) :: map()
  defdelegate truncate_content(result, max_chars), to: Jidoka.Web.Runtime

  @doc false
  @spec validate_public_url(term()) :: :ok | {:error, Exception.t()}
  defdelegate validate_public_url(url), to: Jidoka.Web.Runtime

  @doc false
  @spec normalize_browser_error(atom(), term()) :: Exception.t()
  defdelegate normalize_browser_error(operation, reason), to: Jidoka.Web.Runtime

  defp normalize_entries([]), do: {:ok, []}

  defp normalize_entries(entries) do
    if length(entries) > 1 do
      {:error, "declare at most one web capability per Jidoka agent"}
    else
      entries
      |> Enum.reduce_while({:ok, []}, fn mode, {:ok, acc} ->
        case new(mode) do
          {:ok, web} -> {:cont, {:ok, acc ++ [web]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp normalize_mode(mode) when is_atom(mode) and mode in @modes, do: {:ok, mode}

  defp normalize_mode(mode) when is_binary(mode) do
    mode
    |> String.trim()
    |> case do
      "search" -> {:ok, :search}
      "read_only" -> {:ok, :read_only}
      other -> {:error, invalid_mode_message(other)}
    end
  end

  defp normalize_mode(mode), do: {:error, invalid_mode_message(mode)}

  defp invalid_mode_message(mode) do
    "web capability mode must be :search or :read_only, got: #{inspect(mode)}"
  end

  defp imported_mode(%{mode: mode}), do: mode
  defp imported_mode(%{"mode" => mode}), do: mode
  defp imported_mode(mode), do: mode

  defp tools_for(:search), do: @search_tools
  defp tools_for(:read_only), do: @read_only_tools
end
