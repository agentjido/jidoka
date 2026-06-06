defmodule Jidoka.Memory.Runtime do
  @moduledoc false

  alias Jidoka.Agent
  alias Jidoka.Context
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
        store = store_with_policy(store, memory, request.context, opts)

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
      context = normalize_context(Keyword.get(opts, :context, %{}))
      store = store_with_policy(store, spec.memory, context, opts)

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

  @spec capture_turn(Agent.Spec.t(), Turn.Request.t(), Jidoka.Turn.Result.t(), keyword()) ::
          {:ok, Memory.WriteResult.t() | nil} | {:error, term()}
  def capture_turn(%Agent.Spec{memory: memory} = spec, %Turn.Request{} = request, result, opts) do
    if Agent.Spec.Memory.capture_conversation?(memory) do
      content = "User: #{request.input}\nAssistant: #{result.content}"
      write(spec, content, capture_opts(request, opts))
    else
      {:ok, nil}
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

  defp store_with_policy(store, nil, _context, _opts), do: store

  defp store_with_policy(store, %Agent.Spec.Memory{} = memory, context, opts) do
    memory_opts =
      []
      |> maybe_put(:namespace, resolve_namespace(memory.namespace, context))
      |> maybe_put(:scope, memory.scope)
      |> maybe_put(:session_id, Keyword.get(opts, :session_id))

    merge_store_opts(store, memory_opts)
  end

  defp merge_store_opts({module, opts}, memory_opts),
    do: {module, Keyword.merge(opts, memory_opts)}

  defp merge_store_opts(module, memory_opts) when is_atom(module), do: {module, memory_opts}

  defp resolve_namespace(nil, _context), do: nil
  defp resolve_namespace(namespace, _context) when is_binary(namespace), do: namespace
  defp resolve_namespace({:context, key}, %Context{} = context), do: Context.get(context, key)
  defp resolve_namespace(namespace, _context), do: to_string(namespace)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_context(%Context{} = context), do: context
  defp normalize_context(context), do: Context.from_data!(context)

  defp capture_opts(%Turn.Request{} = request, opts) do
    opts
    |> Keyword.put(:context, request.context)
    |> Keyword.put(:metadata, %{
      "class" => :episodic,
      "kind" => :conversation,
      "source" => "jidoka_capture",
      "request_id" => request.request_id
    })
  end
end
