defmodule Jidoka.Runtime.Context do
  @moduledoc false

  alias Jidoka.Agent.Spec.Operation, as: OperationSpec
  alias Jidoka.Context
  alias Jidoka.Effect
  alias Jidoka.Schema
  alias Jidoka.Turn

  @spec llm(Turn.State.t(), keyword() | map()) :: {:ok, Context.t()} | {:error, term()}
  def llm(%Turn.State{} = state, attrs \\ []) do
    Context.from_turn_state(state, attrs)
  end

  @spec llm!(Turn.State.t(), keyword() | map()) :: Context.t()
  def llm!(%Turn.State{} = state, attrs \\ []) do
    case llm(state, attrs) do
      {:ok, context} -> context
      {:error, reason} -> raise ArgumentError, "invalid LLM context: #{inspect(reason)}"
    end
  end

  @spec operation(Turn.State.t(), Effect.Intent.t(), keyword()) ::
          {:ok, Context.t()} | {:error, term()}
  def operation(%Turn.State{} = state, %Effect.Intent{kind: :operation} = intent, opts \\ []) do
    with {:ok, request} <- Effect.OperationRequest.from_input(intent.payload) do
      operation = operation_for(state, request.name)
      operation_match = operation_match_data(operation, request)

      Context.from_operation(
        state,
        request,
        operation,
        operation_match,
        intent,
        runtime: Keyword.get(opts, :operation_context, %{})
      )
    end
  end

  @spec operation!(Turn.State.t(), Effect.Intent.t(), keyword()) :: Context.t()
  def operation!(%Turn.State{} = state, %Effect.Intent{} = intent, opts \\ []) do
    case operation(state, intent, opts) do
      {:ok, context} -> context
      {:error, reason} -> raise ArgumentError, "invalid operation context: #{inspect(reason)}"
    end
  end

  @spec operation_match_data(OperationSpec.t() | nil, Effect.OperationRequest.t()) :: map()
  def operation_match_data(operation, %Effect.OperationRequest{} = request) do
    %{
      name: request.name,
      kind: operation_kind(operation),
      source: operation_source(operation),
      metadata: operation_metadata(operation)
    }
  end

  defp operation_for(%Turn.State{spec: %{operations: operations}}, name) do
    Enum.find(operations, &(&1.name == name))
  end

  defp operation_kind(%OperationSpec{} = operation), do: OperationSpec.kind(operation)
  defp operation_kind(_operation), do: :operation

  defp operation_source(%OperationSpec{metadata: metadata}) when is_map(metadata) do
    Schema.get_key(metadata, :source) || Schema.get_key(metadata, :runtime)
  end

  defp operation_source(_operation), do: nil

  defp operation_metadata(%OperationSpec{metadata: metadata}) when is_map(metadata), do: metadata
  defp operation_metadata(_operation), do: %{}
end
