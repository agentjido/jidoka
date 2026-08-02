defmodule Jidoka.Runtime.Context do
  @moduledoc false

  alias Jidoka.Agent.Spec.Operation, as: OperationSpec
  alias Jidoka.Context
  alias Jidoka.Effect
  alias Jidoka.Schema
  alias Jidoka.Turn

  @spec llm(Turn.State.t(), keyword() | map()) :: {:ok, Context.t()} | {:error, term()}
  def llm(%Turn.State{} = state, attrs \\ []) do
    from_turn_state(state, attrs)
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

      from_operation(
        state,
        request,
        operation,
        operation_match,
        intent,
        runtime: runtime(state, opts, :operation_context)
      )
    end
  end

  @doc false
  @spec from_turn_state(Turn.State.t(), keyword() | map()) :: {:ok, Context.t()} | {:error, term()}
  def from_turn_state(%Turn.State{} = state, attrs \\ []) do
    attrs = Schema.normalize_attrs(attrs)

    Context.new(
      Map.merge(
        %{
          agent_id: state.spec.id,
          request_id: state.request.request_id,
          session_id: session_id(state.request.metadata, attrs),
          loop_index: state.loop_index,
          input: state.request.input,
          data: Context.data(state.request.context),
          runtime: Context.runtime(state.request.context),
          request_metadata: state.request.metadata,
          spec: state.spec,
          plan: state.plan,
          request: state.request,
          agent_state: state.agent_state,
          result: state.result,
          result_value: state.result_value
        },
        attrs
      )
    )
  end

  @doc false
  @spec from_turn_state!(Turn.State.t(), keyword() | map()) :: Context.t()
  def from_turn_state!(%Turn.State{} = state, attrs \\ []) do
    case from_turn_state(state, attrs) do
      {:ok, context} -> context
      {:error, reason} -> raise ArgumentError, "invalid runtime context: #{inspect(reason)}"
    end
  end

  @doc false
  @spec from_operation(
          Turn.State.t(),
          Effect.OperationRequest.t(),
          OperationSpec.t() | nil,
          map(),
          Effect.Intent.t(),
          keyword() | map()
        ) :: {:ok, Context.t()} | {:error, term()}
  def from_operation(
        %Turn.State{} = state,
        %Effect.OperationRequest{} = request,
        operation,
        operation_match,
        %Effect.Intent{} = intent,
        attrs \\ []
      )
      when is_map(operation_match) do
    attrs = Schema.normalize_attrs(attrs)

    from_turn_state(
      state,
      Map.merge(
        %{
          boundary: :operation,
          operation: request.name,
          operation_kind: Map.get(operation_match, :kind),
          operation_source: Map.get(operation_match, :source),
          arguments: request.arguments,
          operation_metadata: Map.get(operation_match, :metadata, %{}),
          idempotency: operation_idempotency(operation, intent),
          idempotency_key: intent.idempotency_key
        },
        attrs
      )
    )
  end

  @doc false
  @spec from_operation!(
          Turn.State.t(),
          Effect.OperationRequest.t(),
          OperationSpec.t() | nil,
          map(),
          Effect.Intent.t(),
          keyword() | map()
        ) :: Context.t()
  def from_operation!(state, request, operation, operation_match, intent, attrs \\ []) do
    case from_operation(state, request, operation, operation_match, intent, attrs) do
      {:ok, context} -> context
      {:error, reason} -> raise ArgumentError, "invalid operation context: #{inspect(reason)}"
    end
  end

  @spec operation!(Turn.State.t(), Effect.Intent.t(), keyword()) :: Context.t()
  def operation!(%Turn.State{} = state, %Effect.Intent{} = intent, opts \\ []) do
    case operation(state, intent, opts) do
      {:ok, context} -> context
      {:error, reason} -> raise ArgumentError, "invalid operation context: #{inspect(reason)}"
    end
  end

  @doc false
  @spec runtime(Turn.State.t(), keyword(), atom()) :: map()
  def runtime(%Turn.State{} = state, opts, context_key) when is_list(opts) and is_atom(context_key) do
    state.request.context
    |> Context.runtime()
    |> Map.merge(normalize_runtime(Keyword.get(opts, context_key, %{})))
    |> maybe_put_cancellation(Keyword.get(opts, :cancellation))
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

  defp operation_idempotency(%OperationSpec{idempotency: idempotency}, _intent), do: idempotency
  defp operation_idempotency(_operation, %Effect.Intent{idempotency: idempotency}), do: idempotency

  defp session_id(request_metadata, attrs) do
    get_any(attrs, [:session_id, "session_id"]) ||
      get_any(request_metadata, [:session_id, "session_id"])
  end

  defp get_any(map, keys) when is_map(map), do: Enum.find_value(keys, &Map.get(map, &1))

  defp normalize_runtime(runtime) when is_map(runtime), do: runtime
  defp normalize_runtime(_runtime), do: %{}

  defp maybe_put_cancellation(runtime, nil), do: runtime
  defp maybe_put_cancellation(runtime, cancellation), do: Map.put(runtime, :cancellation, cancellation)
end
