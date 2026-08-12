defmodule Jidoka.Extension.BuiltIn do
  @moduledoc "Behaviour for a trusted in-process extension factory."

  alias Jidoka.Extension.{Binding, Slot}

  @callback open(Binding.t(), map(), map()) :: {:ok, term(), Slot.t() | map()} | {:error, term()}
end
