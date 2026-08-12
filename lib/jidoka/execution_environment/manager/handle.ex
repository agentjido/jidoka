defmodule Jidoka.ExecutionEnvironment.Manager.Handle do
  @moduledoc "Opaque transient handle owned by one lifecycle manager."

  @enforce_keys [:manager, :token]
  defstruct [:manager, :token]

  @type t :: %__MODULE__{manager: pid(), token: reference()}

  @doc false
  @spec new(pid(), reference()) :: t()
  def new(manager, token) when is_pid(manager) and is_reference(token),
    do: %__MODULE__{manager: manager, token: token}

  @doc false
  @spec identity(t()) :: {pid(), reference()}
  def identity(%__MODULE__{manager: manager, token: token}), do: {manager, token}
end
