defmodule Jidoka.Memory.Runtime do
  @moduledoc false

  alias Jidoka.Agent
  alias Jidoka.Memory
  alias Jidoka.Turn

  @spec recall(Agent.Spec.t(), Turn.Request.t(), keyword()) ::
          {:ok, Memory.RecallResult.t() | nil} | {:error, term()}
  def recall(%Agent.Spec{memory: nil}, %Turn.Request{}, _opts), do: {:ok, nil}

  def recall(%Agent.Spec{memory: %{enabled: false}}, %Turn.Request{}, _opts), do: {:ok, nil}

  def recall(%Agent.Spec{} = spec, %Turn.Request{} = request, opts) do
    case Keyword.fetch(opts, :memory_store) do
      {:ok, store} ->
        memory = spec.memory

        recall_request =
          Memory.RecallRequest.new!(
            agent_id: spec.id,
            session_id: memory_session_id(memory, opts),
            scope: memory.scope,
            query: request.input,
            limit: memory.max_entries,
            metadata: memory.metadata
          )

        Memory.Store.recall(store, recall_request)

      :error ->
        {:ok, nil}
    end
  end

  @spec write(Agent.Spec.t(), String.t(), keyword()) ::
          {:ok, Memory.WriteResult.t()} | {:error, term()}
  def write(%Agent.Spec{} = spec, content, opts) when is_binary(content) do
    with {:ok, store} <- fetch_memory_store(opts) do
      entry =
        Memory.Entry.new!(
          [
            agent_id: spec.id,
            session_id: write_session_id(spec.memory, opts),
            content: content,
            metadata: Keyword.get(opts, :metadata, %{})
          ],
          Keyword.take(opts, [:id_generator])
        )

      request = Memory.WriteRequest.new!(entry: entry)
      Memory.Store.write(store, request)
    end
  end

  defp memory_session_id(%{scope: :session}, opts), do: Keyword.get(opts, :session_id)
  defp memory_session_id(_memory, _opts), do: nil

  defp write_session_id(%{scope: :session}, opts), do: Keyword.get(opts, :session_id)
  defp write_session_id(_memory, _opts), do: nil

  defp fetch_memory_store(opts) do
    case Keyword.fetch(opts, :memory_store) do
      {:ok, store} -> {:ok, store}
      :error -> {:error, :missing_memory_store}
    end
  end
end
