defmodule Jidoka.Extension.PermissionSet do
  @moduledoc "Portable least-authority permission grant for one extension."

  @version 1
  @allowed ~w(context policy_advice providers results state tools ui_data host_process execution_environment)
  @enforce_keys [:values]
  defstruct version: @version, values: []

  @type t :: %__MODULE__{version: 1, values: [String.t()]}

  @doc "Builds a sorted unique permission set."
  @spec new(term()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = set), do: {:ok, set}

  def new(values) when is_list(values) do
    normalized = values |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort()

    if Enum.all?(normalized, &(&1 in @allowed)) do
      {:ok, %__MODULE__{values: normalized}}
    else
      {:error, {:invalid_extension_permissions, normalized -- @allowed}}
    end
  end

  def new(value), do: {:error, {:invalid_extension_permissions, value}}

  @doc "Builds a permission set or raises."
  @spec new!(term()) :: t()
  def new!(values) do
    case new(values) do
      {:ok, set} -> set
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  @doc "Tests whether the grant is within a host allowance."
  @spec subset?(t(), [String.t()] | :all) :: boolean()
  def subset?(%__MODULE__{}, :all), do: true
  def subset?(%__MODULE__{values: values}, allowed), do: MapSet.subset?(MapSet.new(values), MapSet.new(allowed))

  @doc "Projects the permission set."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = set), do: %{"version" => set.version, "values" => set.values}
end
