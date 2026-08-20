defmodule Jidoka.Operation.Capability do
  @moduledoc """
  Runtime-neutral operation execution port.

  Operation sources return this function contract. Runtime code consumes the
  same contract without owning its type.
  """

  @type t ::
          (Jidoka.Effect.Intent.t(), Jidoka.Effect.Journal.t(), Jidoka.Context.t() ->
             {:ok, term()}
             | {:hibernate, Jidoka.Operation.Continuation.t()}
             | {:error, term()})

  @doc false
  @spec missing(Jidoka.Effect.Intent.t(), Jidoka.Effect.Journal.t(), Jidoka.Context.t()) ::
          {:error, :missing_operations_capability}
  def missing(_intent, _journal, _context), do: {:error, :missing_operations_capability}
end
