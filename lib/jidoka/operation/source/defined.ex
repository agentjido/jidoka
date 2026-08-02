defmodule Jidoka.Operation.Source.Defined do
  @moduledoc false

  @behaviour Jidoka.Operation.Source

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Operation.Source

  @enforce_keys [:source, :operations]
  defstruct [:source, :operations, metadata: []]

  @type t :: %__MODULE__{
          source: Source.source(),
          operations: [Operation.t()],
          metadata: [map()]
        }

  @spec new!(Source.source(), [Operation.t()], [map()]) :: t()
  def new!(%_{} = source, operations, metadata \\ [])
      when is_list(operations) and is_list(metadata) do
    %__MODULE__{source: source, operations: operations, metadata: metadata}
  end

  @impl true
  def operations(%__MODULE__{operations: operations}, _opts), do: {:ok, operations}

  @impl true
  def capability(%__MODULE__{source: source}, opts), do: Source.capability(source, opts)

  @impl true
  def metadata(%__MODULE__{metadata: metadata}, _opts), do: {:ok, metadata}
end
