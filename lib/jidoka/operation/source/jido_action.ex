defmodule Jidoka.Operation.Source.JidoAction do
  @moduledoc """
  Operation source backed by one or more Jido Action modules.

  The source accepts normalized operation contracts. This lets agent authoring
  apply descriptions, controls, approval policy, and source metadata before the
  common operation-source compiler builds the runtime route.
  """

  @behaviour Jidoka.Operation.Source

  alias Jidoka.Adapter.Jido.Actions
  alias Jidoka.Agent.Spec.Operation

  @enforce_keys [:actions, :operations]
  defstruct actions: [], operations: [], metadata: []

  @type t :: %__MODULE__{
          actions: [module()],
          operations: [Operation.t()],
          metadata: [map()]
        }

  @doc "Builds a Jido Action operation source."
  @spec new!([module()], [Operation.t()], keyword()) :: t()
  def new!(actions, operations, opts \\ []) when is_list(actions) and is_list(operations) do
    %__MODULE__{
      actions: actions,
      operations: operations,
      metadata: Keyword.get(opts, :metadata, [])
    }
  end

  @impl true
  def operations(%__MODULE__{operations: operations}, _opts), do: {:ok, operations}

  @impl true
  def capability(%__MODULE__{actions: actions}, opts), do: {:ok, Actions.operations(actions, opts)}

  @impl true
  def metadata(%__MODULE__{metadata: metadata}, _opts), do: {:ok, metadata}
end
