defmodule Jidoka.Memory.Runtime do
  @moduledoc false

  alias Jidoka.Agent
  alias Jidoka.Context
  alias Jidoka.Id
  alias Jidoka.Memory
  alias Jidoka.Memory.Route
  alias Jidoka.Turn

  @spec recall(Agent.Spec.t(), Turn.Request.t(), keyword()) ::
          {:ok, Memory.RecallResult.t() | nil} | {:error, term()}
  def recall(%Agent.Spec{memory: nil}, %Turn.Request{}, _opts), do: {:ok, nil}

  def recall(%Agent.Spec{memory: %{enabled: false}}, %Turn.Request{}, _opts), do: {:ok, nil}

  def recall(%Agent.Spec{} = spec, %Turn.Request{} = request, opts) do
    case Keyword.fetch(opts, :memory_store) do
      {:ok, store} ->
        memory = spec.memory

        with {:ok, route} <- resolve_route(memory, spec.id, request.context, opts) do
          recall_request =
            Memory.RecallRequest.new!(
              route: route,
              query: request.input,
              limit: memory.max_entries,
              metadata: memory.metadata
            )

          Memory.Store.recall(store, recall_request)
        end

      :error ->
        {:ok, nil}
    end
  end

  @spec write(Agent.Spec.t(), String.t(), keyword()) ::
          {:ok, Memory.WriteResult.t()} | {:error, term()}
  def write(%Agent.Spec{} = spec, content, opts) when is_binary(content) do
    with {:ok, store} <- fetch_memory_store(opts) do
      context = normalize_context(Keyword.get(opts, :context, %{}))

      with {:ok, route} <- resolve_route(spec.memory, spec.id, context, opts) do
        entry_attrs =
          [
            id: Keyword.get(opts, :entry_id),
            agent_id: spec.id,
            session_id: route.session_id,
            content: content,
            metadata: Keyword.get(opts, :metadata, %{})
          ]
          |> Enum.reject(&nil_attribute?/1)

        entry = Memory.Entry.new!(entry_attrs, Keyword.take(opts, [:id_generator]))

        request =
          Memory.WriteRequest.new!(
            entry: entry,
            route: route,
            idempotency_key: Keyword.get(opts, :idempotency_key)
          )

        Memory.Store.write(store, request)
      end
    end
  end

  @spec capture_turn(Agent.Spec.t(), Turn.Request.t(), Jidoka.Turn.Result.t(), keyword()) ::
          {:ok, Memory.WriteResult.t() | nil} | {:error, term()}
  def capture_turn(%Agent.Spec{memory: memory} = spec, %Turn.Request{} = request, result, opts) do
    if Agent.Spec.Memory.capture_conversation?(memory) do
      content = "User: #{request.input}\nAssistant: #{result.content}"
      capture_id = capture_id(spec, request, opts, :conversation)
      write(spec, content, capture_opts(request, opts, capture_id, :conversation))
    else
      {:ok, nil}
    end
  end

  @doc false
  @spec capture_id(Agent.Spec.t(), Turn.Request.t(), keyword(), atom()) :: String.t()
  def capture_id(%Agent.Spec{} = spec, %Turn.Request{} = request, opts, capture_kind)
      when is_list(opts) and is_atom(capture_kind) do
    Id.stable("mem", [
      spec.id,
      Keyword.get(opts, :session_id, "direct"),
      request.request_id,
      capture_kind
    ])
  end

  defp fetch_memory_store(opts) do
    case Keyword.fetch(opts, :memory_store) do
      {:ok, store} -> {:ok, store}
      :error -> {:error, :missing_memory_store}
    end
  end

  defp resolve_route(nil, agent_id, _context, _opts),
    do: Route.new(kind: :agent, agent_id: agent_id)

  defp resolve_route(%Agent.Spec.Memory{} = memory, agent_id, context, opts) do
    with {:ok, namespace} <- resolve_namespace(memory.namespace, context) do
      cond do
        is_binary(namespace) and memory.scope == :session ->
          {:error, {:ambiguous_memory_route, :session, namespace}}

        is_binary(namespace) ->
          Route.new(kind: :namespace, agent_id: agent_id, namespace: namespace)

        memory.scope == :session ->
          with {:ok, session_id} <- resolve_session_id(memory, opts) do
            Route.new(kind: :session, agent_id: agent_id, session_id: session_id)
          end

        true ->
          Route.new(kind: :agent, agent_id: agent_id)
      end
    end
  end

  defp resolve_namespace(nil, _context), do: {:ok, nil}
  defp resolve_namespace(namespace, _context) when is_binary(namespace), do: {:ok, namespace}

  defp resolve_namespace({:context, key}, %Context{} = context) do
    case Context.fetch(context, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} when not is_nil(value) -> {:ok, to_string(value)}
      _missing -> {:error, {:missing_memory_namespace_context, key}}
    end
  end

  defp resolve_namespace(namespace, _context), do: {:ok, to_string(namespace)}

  defp resolve_session_id(%Agent.Spec.Memory{scope: :session}, opts) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) and session_id != "" -> {:ok, session_id}
      _session_id -> {:error, :missing_memory_session_id}
    end
  end

  defp resolve_session_id(%Agent.Spec.Memory{}, opts), do: {:ok, Keyword.get(opts, :session_id)}

  defp normalize_context(%Context{} = context), do: context
  defp normalize_context(context), do: Context.from_data!(context)

  defp capture_opts(%Turn.Request{} = request, opts, capture_id, capture_kind) do
    opts
    |> Keyword.put(:context, request.context)
    |> Keyword.put(:entry_id, capture_id)
    |> Keyword.put(:idempotency_key, capture_id)
    |> Keyword.put(:metadata, %{
      "class" => :episodic,
      "kind" => capture_kind,
      "source" => "jidoka_capture",
      "request_id" => request.request_id,
      "session_id" => Keyword.get(opts, :session_id)
    })
  end

  defp nil_attribute?({_key, value}), do: is_nil(value)
end
