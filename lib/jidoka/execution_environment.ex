defmodule Jidoka.ExecutionEnvironment do
  @moduledoc """
  Provider-neutral contracts for constrained execution.

  Requested policy, trusted profile data, durable identity, checkpoints, and
  confirmed evidence are separate public data types.
  """

  alias Jidoka.ExecutionEnvironment.Contract

  @doc "Projects a constrained-execution contract into stable JSON-safe data."
  @spec project(struct()) :: map()
  def project(%_{} = contract), do: Contract.project(contract)

  @doc "Returns an immutable SHA-256 digest for portable contract data."
  @spec digest(struct() | map()) :: String.t()
  def digest(value) do
    value
    |> Contract.project()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end
end
