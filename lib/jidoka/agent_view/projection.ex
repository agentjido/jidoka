defmodule Jidoka.AgentView.Projection do
  @moduledoc false

  alias Jido.AI.Request

  @spec snapshot_attrs(module(), Request.server(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def snapshot_attrs(view_module, agent_ref, input, opts)
      when is_atom(view_module) and is_list(opts) do
    with {:ok, projection} <- Jidoka.Agent.View.snapshot(agent_ref, opts) do
      {:ok,
       %{
         agent_id: projection_agent_id(projection, view_module, input),
         conversation_id: view_module.conversation_id(input),
         runtime_context: view_module.runtime_context(input),
         visible_messages: projection.visible_messages,
         streaming_message: projection.streaming_message,
         llm_context: projection.llm_context,
         events: projection.events,
         status: :idle,
         error: nil,
         error_text: nil,
         outcome: nil,
         metadata: snapshot_metadata(projection, view_module, agent_ref, input, opts)
       }}
    end
  end

  @spec visible_messages(map()) :: [map()]
  def visible_messages(%{visible_messages: messages, streaming_message: nil}), do: messages

  def visible_messages(%{visible_messages: messages, streaming_message: streaming_message}) do
    messages ++ [streaming_message]
  end

  defp projection_agent_id(projection, view_module, input) do
    case Map.get(projection, :agent_id) do
      id when is_binary(id) and id != "" -> id
      id when is_atom(id) -> Atom.to_string(id)
      id when not is_nil(id) -> to_string(id)
      _ -> view_module.agent_id(input)
    end
  end

  defp snapshot_metadata(projection, view_module, agent_ref, input, opts) do
    conversation_id = view_module.conversation_id(input)

    %{
      projection: %{
        context_ref: Map.get(projection, :context_ref),
        thread_id: Map.get(projection, :thread_id),
        thread_rev: Map.get(projection, :thread_rev),
        entry_count: Map.get(projection, :entry_count)
      }
    }
    |> maybe_put(:request_summary, latest_request_summary(agent_ref, Keyword.get(opts, :request_id)))
    |> maybe_put(:handoff_owner, Jidoka.Handoff.OwnerStore.owner(conversation_id))
  end

  defp latest_request_summary(agent_ref, request_id) do
    case Jidoka.Inspection.inspect_request(agent_ref) do
      {:ok, %{request_id: ^request_id} = summary} when is_binary(request_id) -> summary
      {:ok, summary} when is_nil(request_id) -> summary
      _ -> nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
