defmodule JidokaExample.MemoryAgent.Actions.RememberPreference do
  @moduledoc false

  use Jidoka.Action,
    name: "remember_preference",
    description: "Stores a user preference in Jidoka memory backed by jido_memory.",
    schema:
      Zoi.object(%{
        text: Zoi.string(),
        tags: Zoi.array(Zoi.string()) |> Zoi.default([])
      })

  @impl true
  def run(params, context) do
    with {:ok, spec} <- fetch_context(context, :jidoka_spec),
         {:ok, memory_store} <- fetch_context(context, :memory_store),
         {:ok, session_id} <- fetch_context(context, :session_id),
         text when is_binary(text) and text != "" <- normalized_text(params),
         {:ok, result} <-
           Jidoka.Harness.write_memory(spec, text,
             memory_store: memory_store,
             session_id: session_id,
             metadata: %{
               "class" => :semantic,
               "kind" => :preference,
               "tags" => tags(params),
               "source" => "memory_agent"
             }
           ) do
      {:ok,
       %{
         "remembered" => true,
         "memory_id" => result.entry.id,
         "content" => result.entry.content
       }}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :missing_memory_text}
    end
  end

  defp fetch_context(context, key) do
    case Map.get(context, key, Map.get(context, Atom.to_string(key))) do
      nil -> {:error, {:missing_context, key}}
      value -> {:ok, value}
    end
  end

  defp normalized_text(params) do
    params
    |> get(:text)
    |> to_string()
    |> String.trim()
  end

  defp tags(params) do
    params
    |> get(:tags, [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp get(params, key, default \\ nil),
    do: Map.get(params, key, Map.get(params, Atom.to_string(key), default))
end
