defmodule Jidoka.ImportedAgent.Spec.Validator do
  @moduledoc false

  @spec validate_existing(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate_existing(%{} = spec, opts) do
    with :ok <- validate_context(spec.context),
         {:ok, normalized_output} <- normalize_output(spec.output),
         {:ok, normalized_compaction} <- Jidoka.Compaction.normalize_imported(spec.compaction),
         {:ok, normalized_memory} <- Jidoka.Memory.normalize_imported(spec.memory),
         {:ok, _character_spec} <- validate_character(spec.character, Keyword.get(opts, :available_characters, %{})),
         {:ok, normalized_skills} <- Jidoka.Skill.normalize_imported(spec.skills, spec.skill_paths),
         {:ok, normalized_mcp_tools} <- Jidoka.MCP.normalize_imported(spec.mcp_tools),
         {:ok, spec} <- validate_tools(spec, Keyword.get(opts, :available_tools, %{})),
         {:ok, spec} <- validate_skills(spec, Keyword.get(opts, :available_skills, %{})),
         {:ok, spec} <- validate_subagents(spec, Keyword.get(opts, :available_subagents, %{})),
         {:ok, spec} <- validate_workflows(spec, Keyword.get(opts, :available_workflows, %{})),
         {:ok, spec} <- validate_handoffs(spec, Keyword.get(opts, :available_handoffs, %{})),
         {:ok, spec} <- validate_web(spec),
         {:ok, spec} <- validate_plugins(spec, Keyword.get(opts, :available_plugins, %{})),
         {:ok, spec} <- validate_hooks(spec, Keyword.get(opts, :available_hooks, %{})) do
      spec
      |> Map.merge(%{
        memory: normalized_memory,
        compaction: normalized_compaction,
        output: normalized_output,
        skills: (normalized_skills && normalized_skills.refs) || [],
        skill_paths: (normalized_skills && normalized_skills.load_paths) || [],
        mcp_tools: normalized_mcp_tools
      })
      |> validate_guardrails(Keyword.get(opts, :available_guardrails, %{}))
    end
  end

  @spec validate_parsed(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate_parsed(%{} = spec, opts) do
    with {:ok, normalized_model} <- normalize_model(spec.model),
         :ok <- validate_model(normalized_model),
         :ok <- validate_context(spec.context),
         {:ok, normalized_output} <- normalize_output(spec.output),
         {:ok, normalized_compaction} <- Jidoka.Compaction.normalize_imported(spec.compaction),
         {:ok, normalized_memory} <- Jidoka.Memory.normalize_imported(spec.memory),
         {:ok, _character_spec} <- validate_character(spec.character, Keyword.get(opts, :available_characters, %{})),
         {:ok, normalized_skills} <- Jidoka.Skill.normalize_imported(spec.skills, spec.skill_paths),
         {:ok, normalized_mcp_tools} <- Jidoka.MCP.normalize_imported(spec.mcp_tools),
         {:ok, normalized_spec} <-
           validate_tools(
             Map.merge(spec, %{
               model: normalized_model,
               output: normalized_output,
               compaction: normalized_compaction,
               memory: normalized_memory,
               skills: (normalized_skills && normalized_skills.refs) || [],
               skill_paths: (normalized_skills && normalized_skills.load_paths) || [],
               mcp_tools: normalized_mcp_tools
             }),
             Keyword.get(opts, :available_tools, %{})
           ),
         {:ok, normalized_spec} <- validate_skills(normalized_spec, Keyword.get(opts, :available_skills, %{})),
         {:ok, normalized_spec} <- validate_subagents(normalized_spec, Keyword.get(opts, :available_subagents, %{})),
         {:ok, normalized_spec} <- validate_workflows(normalized_spec, Keyword.get(opts, :available_workflows, %{})),
         {:ok, normalized_spec} <- validate_handoffs(normalized_spec, Keyword.get(opts, :available_handoffs, %{})),
         {:ok, normalized_spec} <- validate_web(normalized_spec),
         {:ok, normalized_spec} <- validate_plugins(normalized_spec, Keyword.get(opts, :available_plugins, %{})),
         {:ok, normalized_spec} <- validate_hooks(normalized_spec, Keyword.get(opts, :available_hooks, %{})),
         {:ok, normalized_spec} <- validate_guardrails(normalized_spec, Keyword.get(opts, :available_guardrails, %{})) do
      {:ok, normalized_spec}
    end
  end

  defp normalize_model(model) when is_binary(model) do
    trimmed = String.trim(model)

    cond do
      trimmed == "" ->
        {:error, "model must not be empty"}

      String.contains?(trimmed, ":") ->
        {:ok, trimmed}

      true ->
        case alias_atom(trimmed) do
          {:ok, alias_name} ->
            {:ok, alias_name}

          :error ->
            {:error, "model must be a known alias string like \"fast\" or a direct provider:model string"}
        end
    end
  end

  defp normalize_model(%{} = model) do
    normalized =
      model
      |> Map.take([:provider, :id, :base_url])
      |> Enum.reduce(%{}, fn
        {:base_url, nil}, acc -> acc
        {key, value}, acc when is_binary(value) -> Map.put(acc, key, String.trim(value))
        {key, value}, acc -> Map.put(acc, key, value)
      end)

    {:ok, normalized}
  end

  defp validate_model(model) do
    model
    |> Jidoka.Model.model()
    |> ReqLLM.model()
    |> case do
      {:ok, _model} -> :ok
      {:error, reason} -> {:error, format_model_error(reason)}
    end
  end

  defp validate_context(context) do
    case Jidoka.Context.validate_default(context) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_output(nil), do: {:ok, nil}

  defp normalize_output(%Jidoka.Output{} = output), do: {:ok, output}

  defp normalize_output(%{} = output) do
    case Jidoka.Output.new(output) do
      {:ok, %Jidoka.Output{schema_kind: :json_schema} = normalized} ->
        {:ok, normalized}

      {:ok, %Jidoka.Output{schema_kind: :zoi}} ->
        {:error, "imported output schema must be an object-shaped JSON Schema map"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_output(other),
    do: {:error, "output must be a map with an object-shaped JSON Schema, got: #{inspect(other)}"}

  defp validate_character(nil, _available_characters), do: {:ok, nil}

  defp validate_character(character, _available_characters) when is_map(character) do
    Jidoka.Character.normalize(nil, character, label: "character")
  end

  defp validate_character(character, available_characters) when is_binary(character) and is_map(available_characters) do
    cond do
      map_size(available_characters) == 0 ->
        {:error, "character refs require an available_characters registry when importing Jidoka agents"}

      true ->
        with {:ok, source} <- Jidoka.Character.resolve_character_name(character, available_characters) do
          Jidoka.Character.normalize(nil, source, label: "character #{inspect(character)}")
        end
    end
  end

  defp validate_character(character, _available_characters) do
    {:error, "character must be an inline map or a string ref, got: #{inspect(character)}"}
  end

  defp validate_tools(%{} = spec, available_tools) when is_map(available_tools) do
    cond do
      Enum.uniq(spec.tools) != spec.tools ->
        {:error, "tools must be unique"}

      spec.tools == [] ->
        {:ok, spec}

      map_size(available_tools) == 0 ->
        {:error, "tools require an available_tools registry when importing Jidoka agents"}

      true ->
        case Jidoka.Action.Adapter.resolve_tool_names(spec.tools, available_tools) do
          {:ok, _tool_modules} -> {:ok, spec}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp validate_skills(%{} = spec, available_skills) when is_map(available_skills) do
    cond do
      Enum.uniq(spec.skills) != spec.skills ->
        {:error, "skills must be unique"}

      spec.skills == [] ->
        {:ok, spec}

      true ->
        case Jidoka.Skill.resolve_skill_refs(spec.skills, available_skills) do
          {:ok, _skill_refs} -> {:ok, spec}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp validate_plugins(%{} = spec, available_plugins) when is_map(available_plugins) do
    cond do
      Enum.uniq(spec.plugins) != spec.plugins ->
        {:error, "plugins must be unique"}

      spec.plugins == [] ->
        {:ok, spec}

      map_size(available_plugins) == 0 ->
        {:error, "plugins require an available_plugins registry when importing Jidoka agents"}

      true ->
        case Jidoka.Plugin.resolve_plugin_names(spec.plugins, available_plugins) do
          {:ok, _plugin_modules} -> {:ok, spec}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp validate_web(%{} = spec) do
    case Jidoka.Web.normalize_imported(spec.web) do
      {:ok, _web} -> {:ok, spec}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_subagents(%{} = spec, available_subagents) when is_map(available_subagents) do
    cond do
      not subagents_unique?(spec.subagents) ->
        {:error, "subagent names must be unique"}

      spec.subagents == [] ->
        {:ok, spec}

      map_size(available_subagents) == 0 ->
        {:error, "subagents require an available_subagents registry when importing Jidoka agents"}

      true ->
        spec.subagents
        |> Enum.reduce_while({:ok, spec}, fn subagent, {:ok, spec_acc} ->
          with {:ok, agent_module} <-
                 Jidoka.Subagent.resolve_subagent_name(subagent.agent, available_subagents),
               {:ok, _normalized} <-
                 Jidoka.Subagent.new(
                   agent_module,
                   as: Map.get(subagent, :as),
                   description: Map.get(subagent, :description),
                   target: imported_subagent_target(subagent),
                   timeout: Map.get(subagent, :timeout_ms, 30_000),
                   forward_context: Map.get(subagent, :forward_context, :public),
                   result: Map.get(subagent, :result, :text)
                 ) do
            {:cont, {:ok, spec_acc}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp validate_workflows(%{} = spec, available_workflows) when is_map(available_workflows) do
    cond do
      not workflows_unique?(spec.workflows) ->
        {:error, "workflow capability names must be unique"}

      spec.workflows == [] ->
        {:ok, spec}

      map_size(available_workflows) == 0 ->
        {:error, "workflows require an available_workflows registry when importing Jidoka agents"}

      true ->
        spec.workflows
        |> Enum.reduce_while({:ok, spec}, fn workflow, {:ok, spec_acc} ->
          with {:ok, workflow_module} <-
                 Jidoka.Workflow.Capability.resolve_workflow_name(workflow.workflow, available_workflows),
               {:ok, _normalized} <-
                 Jidoka.Workflow.Capability.new(
                   workflow_module,
                   as: Map.get(workflow, :as),
                   description: Map.get(workflow, :description),
                   timeout: Map.get(workflow, :timeout, 30_000),
                   forward_context: Map.get(workflow, :forward_context, :public),
                   result: Map.get(workflow, :result, :output)
                 ) do
            {:cont, {:ok, spec_acc}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp validate_handoffs(%{} = spec, available_handoffs) when is_map(available_handoffs) do
    cond do
      not handoffs_unique?(spec.handoffs) ->
        {:error, "handoff names must be unique"}

      spec.handoffs == [] ->
        {:ok, spec}

      map_size(available_handoffs) == 0 ->
        {:error, "handoffs require an available_handoffs registry when importing Jidoka agents"}

      true ->
        spec.handoffs
        |> Enum.reduce_while({:ok, spec}, fn handoff, {:ok, spec_acc} ->
          with {:ok, agent_module} <-
                 Jidoka.Handoff.Capability.resolve_handoff_name(handoff.agent, available_handoffs),
               {:ok, _normalized} <-
                 Jidoka.Handoff.Capability.new(
                   agent_module,
                   as: Map.get(handoff, :as),
                   description: Map.get(handoff, :description),
                   target: imported_handoff_target(handoff),
                   forward_context: Map.get(handoff, :forward_context, :public)
                 ) do
            {:cont, {:ok, spec_acc}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp validate_hooks(%{} = spec, available_hooks) when is_map(available_hooks) do
    cond do
      not hooks_unique?(spec.hooks) ->
        {:error, "hook names must be unique within each stage"}

      hooks_empty?(spec.hooks) ->
        {:ok, spec}

      map_size(available_hooks) == 0 ->
        {:error, "hooks require an available_hooks registry when importing Jidoka agents"}

      true ->
        spec.hooks
        |> Enum.reduce_while({:ok, spec}, fn {_stage, hook_names}, {:ok, spec_acc} ->
          case Jidoka.Hook.resolve_hook_names(hook_names, available_hooks) do
            {:ok, _hook_modules} -> {:cont, {:ok, spec_acc}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp validate_guardrails(%{} = spec, available_guardrails) when is_map(available_guardrails) do
    cond do
      not guardrails_unique?(spec.guardrails) ->
        {:error, "guardrail names must be unique within each stage"}

      guardrails_empty?(spec.guardrails) ->
        {:ok, spec}

      map_size(available_guardrails) == 0 ->
        {:error, "guardrails require an available_guardrails registry when importing Jidoka agents"}

      true ->
        spec.guardrails
        |> Enum.reduce_while({:ok, spec}, fn {_stage, guardrail_names}, {:ok, spec_acc} ->
          case Jidoka.Guardrail.resolve_guardrail_names(guardrail_names, available_guardrails) do
            {:ok, _guardrail_modules} -> {:cont, {:ok, spec_acc}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp format_model_error(%{message: message}) when is_binary(message),
    do: message

  defp format_model_error(reason), do: inspect(reason)

  defp hooks_unique?(hooks) do
    Enum.all?(hooks, fn {_stage, hook_names} -> Enum.uniq(hook_names) == hook_names end)
  end

  defp hooks_empty?(hooks) do
    Enum.all?(hooks, fn {_stage, hook_names} -> hook_names == [] end)
  end

  defp guardrails_unique?(guardrails) do
    Enum.all?(guardrails, fn {_stage, guardrail_names} ->
      Enum.uniq(guardrail_names) == guardrail_names
    end)
  end

  defp guardrails_empty?(guardrails) do
    Enum.all?(guardrails, fn {_stage, guardrail_names} -> guardrail_names == [] end)
  end

  defp subagents_unique?(subagents) do
    names =
      Enum.map(subagents, fn subagent ->
        Map.get(subagent, :as) || Map.fetch!(subagent, :agent)
      end)

    Enum.uniq(names) == names
  end

  defp workflows_unique?(workflows) do
    names =
      Enum.map(workflows, fn workflow ->
        Map.get(workflow, :as) || Map.fetch!(workflow, :workflow)
      end)

    Enum.uniq(names) == names
  end

  defp handoffs_unique?(handoffs) do
    names =
      Enum.map(handoffs, fn handoff ->
        Map.get(handoff, :as) || Map.fetch!(handoff, :agent)
      end)

    Enum.uniq(names) == names
  end

  defp imported_subagent_target(%{target: "ephemeral"}), do: :ephemeral

  defp imported_subagent_target(%{target: "peer", peer_id: peer_id})
       when is_binary(peer_id) and peer_id != "" do
    {:peer, peer_id}
  end

  defp imported_subagent_target(%{target: "peer", peer_id_context_key: key})
       when (is_binary(key) and key != "") or is_atom(key) do
    {:peer, {:context, key}}
  end

  defp imported_subagent_target(%{target: target}) do
    target
  end

  defp imported_handoff_target(%{target: "auto"}), do: :auto

  defp imported_handoff_target(%{target: "peer", peer_id: peer_id})
       when is_binary(peer_id) and peer_id != "" do
    {:peer, peer_id}
  end

  defp imported_handoff_target(%{target: "peer", peer_id_context_key: key})
       when (is_binary(key) and key != "") or is_atom(key) do
    {:peer, {:context, key}}
  end

  defp imported_handoff_target(%{target: target}) do
    target
  end

  defp imported_handoff_target(%{agent: _agent}), do: :auto

  defp alias_atom(name) do
    (Map.keys(Jidoka.Model.model_aliases()) ++ Map.keys(Jido.AI.model_aliases()))
    |> Enum.uniq()
    |> Enum.find_value(:error, fn alias_name ->
      if Atom.to_string(alias_name) == name, do: {:ok, alias_name}, else: false
    end)
  end
end
