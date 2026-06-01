defmodule Jidoka.Memory.Store.JidoMemory do
  @moduledoc """
  `Jidoka.Memory.Store` adapter backed by `jido_memory`.

  Jidoka keeps its memory contract small and data-first. This adapter lets that
  contract use the Jido ecosystem's provider/runtime boundary without exposing
  provider details to the turn workflow.
  """

  @behaviour Jidoka.Memory.Store

  alias Jidoka.Memory.Entry
  alias Jidoka.Memory.RecallRequest
  alias Jidoka.Memory.RecallResult
  alias Jidoka.Memory.WriteRequest
  alias Jidoka.Memory.WriteResult

  @default_provider :basic

  @impl true
  def recall(%RecallRequest{} = request, opts) do
    namespace = namespace(request.agent_id, request.session_id, request.scope, opts)

    query =
      %{
        namespace: namespace,
        limit: request.limit,
        order: Keyword.get(opts, :order, :desc)
      }
      |> maybe_put_text_filter(request.query, opts)

    with {:ok, result} <-
           Jido.Memory.Runtime.retrieve(target(request.agent_id), query, runtime_opts(opts)) do
      entries =
        result
        |> Jido.Memory.RetrieveResult.records()
        |> Enum.map(&record_to_entry(&1, request.agent_id, request.session_id))

      RecallResult.new(
        request: request,
        entries: entries,
        metadata: %{
          "provider" => "jido_memory",
          "namespace" => namespace,
          "total_count" => result.total_count
        }
      )
    end
  end

  @impl true
  def write(%WriteRequest{entry: %Entry{} = entry} = request, opts) do
    namespace = namespace(entry.agent_id, entry.session_id, scope(entry), opts)

    attrs = %{
      id: entry.id,
      namespace: namespace,
      class: metadata_value(entry.metadata, :class, :semantic),
      kind: metadata_value(entry.metadata, :kind, :fact),
      text: entry.content,
      content: metadata_value(entry.metadata, :content, %{"content" => entry.content}),
      tags: tags(entry.metadata),
      source: metadata_value(entry.metadata, :source, "jidoka"),
      metadata:
        entry.metadata
        |> Map.put("jidoka_agent_id", entry.agent_id)
        |> maybe_put_metadata("jidoka_session_id", entry.session_id)
    }

    with {:ok, record} <-
           Jido.Memory.Runtime.remember(target(entry.agent_id), attrs, runtime_opts(opts)),
         entry <- record_to_entry(record, entry.agent_id, entry.session_id) do
      WriteResult.new(
        request: request,
        entry: entry,
        metadata: %{"provider" => "jido_memory", "namespace" => namespace}
      )
    end
  end

  @impl true
  def list_entries(opts) do
    with {:ok, namespace} <- list_namespace(opts),
         {:ok, result} <-
           Jido.Memory.Runtime.retrieve(
             target(Keyword.get(opts, :agent_id, "jidoka")),
             %{namespace: namespace, limit: Keyword.get(opts, :limit, 100), order: :asc},
             runtime_opts(opts)
           ) do
      entries =
        result
        |> Jido.Memory.RetrieveResult.records()
        |> Enum.map(&record_to_entry(&1, nil, nil))

      {:ok, entries}
    end
  end

  @doc false
  @spec namespace(String.t(), String.t() | nil, atom(), keyword()) :: String.t()
  def namespace(agent_id, session_id, scope, opts) do
    base = Keyword.get(opts, :namespace)

    cond do
      is_binary(base) and scope == :session and is_binary(session_id) ->
        base <> ":session:" <> session_id

      is_binary(base) ->
        base

      scope == :session and is_binary(session_id) ->
        "agent:" <> to_string(agent_id) <> ":session:" <> session_id

      true ->
        "agent:" <> to_string(agent_id)
    end
  end

  defp list_namespace(opts) do
    cond do
      is_binary(Keyword.get(opts, :list_namespace)) ->
        {:ok, Keyword.fetch!(opts, :list_namespace)}

      is_binary(Keyword.get(opts, :namespace)) ->
        {:ok,
         namespace(
           Keyword.get(opts, :agent_id, "jidoka"),
           Keyword.get(opts, :session_id),
           Keyword.get(opts, :scope, :agent),
           opts
         )}

      is_binary(Keyword.get(opts, :agent_id)) ->
        {:ok,
         namespace(
           Keyword.fetch!(opts, :agent_id),
           Keyword.get(opts, :session_id),
           Keyword.get(opts, :scope, :agent),
           opts
         )}

      true ->
        {:error, :missing_memory_namespace}
    end
  end

  defp runtime_opts(opts) do
    provider_opts =
      opts
      |> Keyword.get(:provider_opts, [])
      |> Keyword.put_new(:store, Keyword.get(opts, :store, Jido.Memory.Store.ETS))

    [
      provider: Keyword.get(opts, :provider, @default_provider),
      provider_opts: provider_opts
    ]
  end

  defp target(agent_id), do: %{id: to_string(agent_id || "jidoka")}

  defp scope(%Entry{session_id: session_id}) when is_binary(session_id), do: :session
  defp scope(%Entry{}), do: :agent

  defp maybe_put_text_filter(query, text, opts) do
    if Keyword.get(opts, :filter_text?, false) and is_binary(text) and String.trim(text) != "" do
      Map.put(query, :text_contains, text)
    else
      query
    end
  end

  defp record_to_entry(record, fallback_agent_id, fallback_session_id) do
    metadata = Map.get(record, :metadata, %{})

    Entry.new!(
      id: record.id,
      agent_id: metadata_value(metadata, :jidoka_agent_id, fallback_agent_id || "jidoka"),
      session_id: metadata_value(metadata, :jidoka_session_id, fallback_session_id),
      content: record_text(record),
      metadata:
        metadata
        |> Map.put("jido_memory_namespace", record.namespace)
        |> Map.put("jido_memory_class", record.class)
        |> Map.put("jido_memory_kind", record.kind)
        |> Map.put("jido_memory_tags", record.tags)
    )
  end

  defp record_text(%{text: text}) when is_binary(text) and text != "", do: text
  defp record_text(%{content: %{"content" => content}}) when is_binary(content), do: content
  defp record_text(%{content: %{content: content}}) when is_binary(content), do: content
  defp record_text(record), do: inspect(record.content)

  defp metadata_value(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp maybe_put_metadata(map, _key, nil), do: map
  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  defp tags(metadata) do
    metadata
    |> metadata_value(:tags, [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end
end
