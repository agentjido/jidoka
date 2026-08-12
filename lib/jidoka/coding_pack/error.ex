defmodule Jidoka.CodingPack.Error do
  @moduledoc "Typed error returned by coding-pack workspace and registration contracts."

  @enforce_keys [:code]
  defstruct [:code, details: %{}]

  @type t :: %__MODULE__{code: atom(), details: map()}

  @doc "Builds a coding-pack error with portable details."
  @spec new(atom(), map()) :: t()
  def new(code, details \\ %{}) when is_atom(code) and is_map(details),
    do: %__MODULE__{code: code, details: details}
end
