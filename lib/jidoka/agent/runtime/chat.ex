defmodule Jidoka.Agent.Chat do
  @moduledoc false

  @spec prepare_chat_opts(keyword(), map() | nil) ::
          {:ok, keyword()} | {:error, term()}
  def prepare_chat_opts(opts, nil) when is_list(opts) do
    with :ok <- reject_tool_context(opts),
         {:ok, context} <- normalize_request_context(opts, %{}, nil),
         {:ok, context} <- attach_conversation(opts, context),
         {:ok, context} <- attach_runtime_character(opts, context),
         {:ok, context} <- attach_runtime_extensions(opts, context),
         {:ok, context} <- attach_runtime_output(opts, context) do
      {:ok, finalize_chat_opts(opts, context)}
    end
  end

  def prepare_chat_opts(opts, config) when is_list(opts) do
    default_context = default_context(config)
    context_schema = context_schema(config)
    ash_tool_config = ash_tool_config(config)

    with :ok <- reject_tool_context(opts),
         {:ok, context} <- normalize_request_context(opts, default_context, context_schema),
         {:ok, context} <- attach_conversation(opts, context),
         {:ok, context} <- attach_runtime_character(opts, context),
         {:ok, context} <- attach_runtime_extensions(opts, context),
         {:ok, context} <- attach_runtime_output(opts, context),
         {:ok, context} <- maybe_prepare_ash_context(context, ash_tool_config) do
      {:ok, finalize_chat_opts(opts, context)}
    end
  end

  defp reject_tool_context(opts) do
    if Keyword.has_key?(opts, :tool_context) do
      {:error, Jidoka.Error.invalid_option(:tool_context, :use_context, value: Keyword.get(opts, :tool_context))}
    else
      :ok
    end
  end

  defp normalize_request_context(opts, default_context, nil) do
    with {:ok, runtime_context} <- Jidoka.Context.normalize(Keyword.get(opts, :context, %{})) do
      {:ok, Jidoka.Context.merge(default_context, runtime_context)}
    end
  end

  defp normalize_request_context(opts, _default_context, context_schema) do
    Jidoka.Context.normalize(Keyword.get(opts, :context, %{}), context_schema)
  end

  defp attach_runtime_character(opts, context) do
    case Keyword.fetch(opts, :character) do
      {:ok, character} ->
        case Jidoka.Character.normalize(nil, character, label: "character") do
          {:ok, normalized} ->
            {:ok, Map.put(context, Jidoka.Character.context_key(), normalized)}

          {:error, reason} ->
            {:error,
             Jidoka.Error.Normalize.chat_option_error({:invalid_character, reason},
               field: :character,
               value: character
             )}
        end

      :error ->
        {:ok, context}
    end
  end

  defp attach_conversation(opts, context) do
    case Keyword.fetch(opts, :conversation) do
      {:ok, conversation_id} when is_binary(conversation_id) ->
        case String.trim(conversation_id) do
          "" ->
            {:error,
             Jidoka.Error.Normalize.chat_option_error({:invalid_conversation, conversation_id},
               field: :conversation,
               value: conversation_id
             )}

          trimmed ->
            {:ok, Map.put(context, Jidoka.Handoff.context_key(), trimmed)}
        end

      {:ok, conversation_id} ->
        {:error,
         Jidoka.Error.Normalize.chat_option_error({:invalid_conversation, conversation_id},
           field: :conversation,
           value: conversation_id
         )}

      :error ->
        {:ok, context}
    end
  end

  defp attach_runtime_extensions(opts, context) do
    with {:ok, hooks} <- Jidoka.Hooks.normalize_request_hooks(Keyword.get(opts, :hooks, nil)),
         {:ok, controls} <-
           Jidoka.Controls.normalize_request_controls(Keyword.get(opts, :controls, Keyword.get(opts, :guardrails, nil))) do
      {:ok,
       context
       |> Jidoka.Hooks.attach_request_hooks(hooks)
       |> Jidoka.Controls.attach_request_controls(controls)}
    else
      {:error, reason} -> {:error, Jidoka.Error.Normalize.chat_option_error(reason)}
    end
  end

  defp attach_runtime_output(opts, context) do
    {:ok, Jidoka.Output.attach_request_option(context, Keyword.get(opts, :output))}
  end

  defp finalize_chat_opts(opts, context) do
    opts
    |> Keyword.drop([:context, :character, :conversation, :hooks, :controls, :guardrails, :output, :start_opts])
    |> Keyword.put(:tool_context, context)
  end

  defp maybe_prepare_ash_context(context, nil), do: {:ok, context}

  defp maybe_prepare_ash_context(context, %{domain: domain, require_actor?: true}) do
    with :ok <- ensure_actor(context),
         {:ok, context} <- ensure_domain(context, domain) do
      {:ok, context}
    end
  end

  defp default_context(%{context: context}) when is_map(context), do: context
  defp default_context(_config), do: %{}

  defp context_schema(%{context_schema: context_schema}), do: context_schema
  defp context_schema(_config), do: nil

  defp ash_tool_config(%{ash: ash}) when is_map(ash), do: ash
  defp ash_tool_config(%{domain: _domain, require_actor?: _require_actor?} = ash), do: ash
  defp ash_tool_config(_config), do: nil

  defp ensure_actor(context) do
    case Map.get(context, :actor, Map.get(context, "actor")) do
      nil -> {:error, Jidoka.Error.missing_context(:actor, value: context)}
      _actor -> :ok
    end
  end

  defp ensure_domain(context, domain) do
    case Map.get(context, :domain, Map.get(context, "domain")) do
      nil ->
        {:ok, Map.put(context, :domain, domain)}

      ^domain ->
        {:ok, Map.put(context, :domain, domain)}

      other ->
        {:error, Jidoka.Error.invalid_context({:domain_mismatch, domain, other}, value: context)}
    end
  end
end
