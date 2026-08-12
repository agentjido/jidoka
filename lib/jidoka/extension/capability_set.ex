defmodule Jidoka.Extension.CapabilitySet do
  @moduledoc "Portable declared extension capability set."

  alias Jidoka.Extension.Identity

  @version 1
  @enforce_keys [:values]
  defstruct version: @version, values: []

  @type t :: %__MODULE__{version: 1, values: [String.t()]}

  @doc "Builds a sorted unique namespaced capability set."
  @spec new(term()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = set), do: {:ok, set}

  def new(values) when is_list(values) do
    normalized = values |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort()

    if Enum.all?(normalized, &Identity.valid_id?/1) do
      {:ok, %__MODULE__{values: normalized}}
    else
      {:error, {:invalid_extension_capabilities, normalized}}
    end
  end

  def new(value), do: {:error, {:invalid_extension_capabilities, value}}

  @doc "Builds a capability set or raises."
  @spec new!(term()) :: t()
  def new!(values) do
    case new(values) do
      {:ok, set} -> set
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  @doc "Projects the capability set."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = set), do: %{"version" => set.version, "values" => set.values}
end
