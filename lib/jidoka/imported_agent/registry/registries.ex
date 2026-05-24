defmodule Jidoka.ImportedAgent.Registries do
  @moduledoc false

  @type t :: %{
          tools: Jidoka.Action.Adapter.registry(),
          characters: Jidoka.Character.registry(),
          skills: Jidoka.Skill.registry(),
          subagents: Jidoka.Subagent.registry(),
          workflows: Jidoka.Workflow.Capability.registry(),
          handoffs: Jidoka.Handoff.Capability.registry(),
          plugins: Jidoka.Plugin.registry(),
          hooks: Jidoka.Hook.registry(),
          guardrails: Jidoka.Guardrail.registry()
        }

  @spec with_registries(keyword(), (t() -> term())) :: term()
  def with_registries(opts, fun) when is_list(opts) and is_function(fun, 1) do
    with {:ok, registries} <- normalize(opts) do
      fun.(registries)
    end
  end

  @spec normalize(keyword()) :: {:ok, t()} | {:error, String.t()}
  def normalize(opts) when is_list(opts) do
    with {:ok, tool_registry} <- available_tool_registry(opts),
         {:ok, character_registry} <- available_character_registry(opts),
         {:ok, skill_registry} <- available_skill_registry(opts),
         {:ok, subagent_registry} <- available_subagent_registry(opts),
         {:ok, workflow_registry} <- available_workflow_registry(opts),
         {:ok, handoff_registry} <- available_handoff_registry(opts),
         {:ok, plugin_registry} <- available_plugin_registry(opts),
         {:ok, hook_registry} <- available_hook_registry(opts),
         {:ok, guardrail_registry} <- available_guardrail_registry(opts) do
      {:ok,
       %{
         tools: tool_registry,
         characters: character_registry,
         skills: skill_registry,
         subagents: subagent_registry,
         workflows: workflow_registry,
         handoffs: handoff_registry,
         plugins: plugin_registry,
         hooks: hook_registry,
         guardrails: guardrail_registry
       }}
    end
  end

  @spec normalize_opts(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def normalize_opts(opts) when is_list(opts) do
    with {:ok, registries} <- normalize(opts) do
      {:ok,
       opts
       |> Keyword.put(:available_tools, registries.tools)
       |> Keyword.put(:available_characters, registries.characters)
       |> Keyword.put(:available_skills, registries.skills)
       |> Keyword.put(:available_subagents, registries.subagents)
       |> Keyword.put(:available_workflows, registries.workflows)
       |> Keyword.put(:available_handoffs, registries.handoffs)
       |> Keyword.put(:available_plugins, registries.plugins)
       |> Keyword.put(:available_hooks, registries.hooks)
       |> Keyword.put(:available_guardrails, registries.guardrails)}
    end
  end

  @spec resolve_hooks(Jidoka.Hooks.stage_map(), Jidoka.Hook.registry()) ::
          {:ok, Jidoka.Hooks.stage_map()} | {:error, String.t()}
  def resolve_hooks(hooks, hook_registry) do
    hooks
    |> Enum.reduce_while({:ok, Jidoka.Hooks.default_stage_map()}, fn {stage, hook_names}, {:ok, acc} ->
      case Jidoka.Hook.resolve_hook_names(hook_names, hook_registry) do
        {:ok, modules} -> {:cont, {:ok, Map.put(acc, stage, modules)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec resolve_guardrails(Jidoka.Guardrails.stage_map(), Jidoka.Guardrail.registry()) ::
          {:ok, Jidoka.Guardrails.stage_map()} | {:error, String.t()}
  def resolve_guardrails(guardrails, guardrail_registry) do
    guardrails
    |> Enum.reduce_while({:ok, Jidoka.Guardrails.default_stage_map()}, fn {stage, guardrail_names}, {:ok, acc} ->
      case Jidoka.Guardrail.resolve_guardrail_names(guardrail_names, guardrail_registry) do
        {:ok, modules} -> {:cont, {:ok, Map.put(acc, stage, modules)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec resolve_skills([String.t()], Jidoka.Skill.registry()) ::
          {:ok, [Jidoka.Skill.ref()]} | {:error, String.t()}
  def resolve_skills(skill_names, skill_registry) do
    Jidoka.Skill.resolve_skill_refs(skill_names, skill_registry)
  end

  @spec resolve_subagents([map()], Jidoka.Subagent.registry()) ::
          {:ok, [Jidoka.Subagent.t()]} | {:error, String.t()}
  def resolve_subagents(subagents, subagent_registry) do
    subagents
    |> Enum.reduce_while({:ok, []}, fn subagent_spec, {:ok, acc} ->
      with {:ok, agent_module} <-
             Jidoka.Subagent.resolve_subagent_name(subagent_spec.agent, subagent_registry),
           {:ok, subagent} <-
             Jidoka.Subagent.new(
               agent_module,
               as: Map.get(subagent_spec, :as),
               description: Map.get(subagent_spec, :description),
               target: imported_subagent_target(subagent_spec),
               timeout: Map.get(subagent_spec, :timeout_ms, 30_000),
               forward_context: Map.get(subagent_spec, :forward_context, :public),
               result: Map.get(subagent_spec, :result, :text)
             ) do
        {:cont, {:ok, acc ++ [subagent]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec resolve_workflows([map()], Jidoka.Workflow.Capability.registry()) ::
          {:ok, [Jidoka.Workflow.Capability.t()]} | {:error, String.t()}
  def resolve_workflows(workflows, workflow_registry) do
    workflows
    |> Enum.reduce_while({:ok, []}, fn workflow_spec, {:ok, acc} ->
      with {:ok, workflow_module} <-
             Jidoka.Workflow.Capability.resolve_workflow_name(workflow_spec.workflow, workflow_registry),
           {:ok, workflow} <-
             Jidoka.Workflow.Capability.new(
               workflow_module,
               as: Map.get(workflow_spec, :as),
               description: Map.get(workflow_spec, :description),
               timeout: Map.get(workflow_spec, :timeout, 30_000),
               forward_context: Map.get(workflow_spec, :forward_context, :public),
               result: Map.get(workflow_spec, :result, :output)
             ) do
        {:cont, {:ok, acc ++ [workflow]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec resolve_handoffs([map()], Jidoka.Handoff.Capability.registry()) ::
          {:ok, [Jidoka.Handoff.Capability.t()]} | {:error, String.t()}
  def resolve_handoffs(handoffs, handoff_registry) do
    handoffs
    |> Enum.reduce_while({:ok, []}, fn handoff_spec, {:ok, acc} ->
      with {:ok, agent_module} <-
             Jidoka.Handoff.Capability.resolve_handoff_name(handoff_spec.agent, handoff_registry),
           {:ok, handoff} <-
             Jidoka.Handoff.Capability.new(
               agent_module,
               as: Map.get(handoff_spec, :as),
               description: Map.get(handoff_spec, :description),
               target: imported_handoff_target(handoff_spec),
               forward_context: Map.get(handoff_spec, :forward_context, :public)
             ) do
        {:cont, {:ok, acc ++ [handoff]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp available_tool_registry(opts) do
    opts
    |> Keyword.get(:available_tools, [])
    |> Jidoka.Action.Adapter.normalize_available_tools()
  end

  defp available_character_registry(opts) do
    opts
    |> Keyword.get(:available_characters, %{})
    |> Jidoka.Character.normalize_available_characters()
  end

  defp available_skill_registry(opts) do
    opts
    |> Keyword.get(:available_skills, [])
    |> Jidoka.Skill.normalize_available_skills()
  end

  defp available_plugin_registry(opts) do
    opts
    |> Keyword.get(:available_plugins, [])
    |> Jidoka.Plugin.normalize_available_plugins()
  end

  defp available_subagent_registry(opts) do
    opts
    |> Keyword.get(:available_subagents, [])
    |> Jidoka.Subagent.normalize_available_subagents()
  end

  defp available_workflow_registry(opts) do
    opts
    |> Keyword.get(:available_workflows, [])
    |> Jidoka.Workflow.Capability.normalize_available_workflows()
  end

  defp available_handoff_registry(opts) do
    opts
    |> Keyword.get(:available_handoffs, [])
    |> Jidoka.Handoff.Capability.normalize_available_handoffs()
  end

  defp available_hook_registry(opts) do
    opts
    |> Keyword.get(:available_hooks, [])
    |> Jidoka.Hook.normalize_available_hooks()
  end

  defp available_guardrail_registry(opts) do
    opts
    |> Keyword.get(:available_guardrails, [])
    |> Jidoka.Guardrail.normalize_available_guardrails()
  end

  defp imported_subagent_target(%{target: "ephemeral"}), do: :ephemeral
  defp imported_subagent_target(%{target: "peer", peer_id: peer_id}), do: {:peer, peer_id}

  defp imported_subagent_target(%{target: "peer", peer_id_context_key: key}),
    do: {:peer, {:context, key}}

  defp imported_handoff_target(%{target: "auto"}), do: :auto
  defp imported_handoff_target(%{target: "peer", peer_id: peer_id}), do: {:peer, peer_id}

  defp imported_handoff_target(%{target: "peer", peer_id_context_key: key}),
    do: {:peer, {:context, key}}

  defp imported_handoff_target(%{target: target}), do: target
  defp imported_handoff_target(%{agent: _agent}), do: :auto
end
