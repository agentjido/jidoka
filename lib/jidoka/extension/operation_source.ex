defmodule Jidoka.Extension.OperationSource do
  @moduledoc "Operation source for tools registered by the trusted extension host."

  @behaviour Jidoka.Operation.Source

  alias Jidoka.Runtime.LocalOperations

  @enforce_keys [:namespace, :operations, :handlers]
  defstruct [:namespace, :operations, :handlers]

  @type t :: %__MODULE__{namespace: String.t(), operations: [Jidoka.Agent.Spec.Operation.t()], handlers: map()}

  @impl true
  def compile(%__MODULE__{} = source, _opts) do
    capability = LocalOperations.operations(source.handlers)
    metadata = [%{"kind" => "extension", "namespace" => source.namespace}]
    Jidoka.Operation.Source.compiled(source.operations, capability, metadata)
  end

  @impl true
  def operations(%__MODULE__{operations: operations}, _opts), do: {:ok, operations}

  @impl true
  def capability(%__MODULE__{handlers: handlers}, _opts), do: {:ok, LocalOperations.operations(handlers)}

  @impl true
  def metadata(%__MODULE__{} = source, _opts) do
    {:ok, [%{"kind" => "extension", "namespace" => source.namespace}]}
  end
end
