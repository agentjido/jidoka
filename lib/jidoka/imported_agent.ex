defmodule Jidoka.ImportedAgent do
  @moduledoc """
  Runtime representation of a constrained JSON/YAML-authored Jidoka agent.

  Imported agents are experimental in the beta. Use them for controlled
  interchange, fixtures, and portability tests backed by explicit registries;
  prefer the Elixir DSL as the canonical authoring surface while the DSL
  settles.

  Importing a spec is constrained data loading, not arbitrary code loading. Raw
  module strings stay invalid; tools, plugins, subagents, workflows, handoffs,
  hooks, guardrails, characters, and skills must resolve through host-provided
  registries.

  Most applications should call `Jidoka.import_agent/2` or
  `Jidoka.import_agent_file/2` rather than this module directly. The struct is
  still documented because public Jidoka APIs return it.
  """

  alias Jidoka.ImportedAgent.{Codec, Definition, Registries, RuntimeCompiler, Spec}

  @enforce_keys [
    :spec,
    :character_spec,
    :runtime_module,
    :tool_modules,
    :skill_refs,
    :mcp_tools,
    :subagents,
    :workflows,
    :handoffs,
    :web,
    :plugin_modules,
    :hook_modules,
    :guardrail_modules
  ]
  defstruct [
    :spec,
    :character_spec,
    :runtime_module,
    :tool_modules,
    :skill_refs,
    :mcp_tools,
    :subagents,
    :workflows,
    :handoffs,
    :web,
    :plugin_modules,
    :hook_modules,
    :guardrail_modules
  ]

  @type t :: %__MODULE__{
          spec: struct(),
          character_spec: Jidoka.Character.spec(),
          runtime_module: module(),
          tool_modules: [module()],
          skill_refs: [term()],
          mcp_tools: [map()],
          subagents: [Jidoka.Subagent.t()],
          workflows: [struct()],
          handoffs: [struct()],
          web: [Jidoka.Web.t()],
          plugin_modules: [module()],
          hook_modules: map(),
          guardrail_modules: map()
        }

  @spec import(map() | binary() | struct(), keyword()) :: {:ok, t()} | {:error, term()}
  def import(source, opts \\ [])

  def import(%Spec{} = spec, opts) do
    Registries.with_registries(opts, fn registries ->
      build_from_source(spec, registries)
    end)
  end

  def import(source, opts) when is_map(source) do
    Registries.with_registries(opts, fn registries ->
      build_from_source(source, registries)
    end)
  end

  def import(source, opts) when is_binary(source) do
    with {:ok, attrs} <- Codec.decode(source, Keyword.get(opts, :format, :auto)) do
      Registries.with_registries(opts, fn registries ->
        build_from_source(attrs, registries)
      end)
    end
  end

  def import(other, _opts),
    do: {:error, "cannot import Jidoka agent from #{inspect(other)}"}

  @spec import_file(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def import_file(path, opts \\ []) when is_binary(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, format} <- Codec.detect_file_format(path, Keyword.get(opts, :format)),
         {:ok, attrs} <- Codec.decode(contents, format),
         expanded_attrs <- Codec.expand_skill_paths(attrs, Path.dirname(path)),
         {:ok, agent} <- __MODULE__.import(expanded_attrs, opts) do
      {:ok, agent}
    else
      {:error, :enoent} ->
        {:error, "could not read agent spec file: #{path}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec start_link(t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_link(%__MODULE__{runtime_module: runtime_module}, opts \\ []) do
    Jidoka.Runtime.start_agent(runtime_module, opts)
  end

  @spec definition(t()) :: map()
  def definition(%__MODULE__{} = agent) do
    Definition.map(
      agent.spec,
      agent.runtime_module,
      agent.character_spec,
      agent.tool_modules,
      agent.skill_refs,
      agent.mcp_tools,
      agent.subagents,
      agent.workflows,
      agent.handoffs,
      agent.web,
      agent.plugin_modules,
      agent.hook_modules,
      agent.guardrail_modules,
      RuntimeCompiler.request_transformer(agent.spec, agent.runtime_module)
    )
  end

  @spec encode(t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{spec: spec}, opts \\ []), do: Codec.encode(spec, opts)

  @doc """
  Formats an imported-agent error for human-readable messages.
  """
  @spec format_error(term()) :: String.t()
  def format_error(reason), do: Codec.format_error(reason)

  defp build(
         %Spec{} = spec,
         tool_registry,
         character_registry,
         skill_registry,
         subagent_registry,
         workflow_registry,
         handoff_registry,
         plugin_registry,
         hook_registry,
         guardrail_registry
       ) do
    with {:ok, direct_tool_modules} <- Jidoka.Action.Adapter.resolve_tool_names(spec.tools, tool_registry),
         {:ok, character_spec} <- resolve_character(spec.character, character_registry),
         {:ok, skill_refs} <- Registries.resolve_skills(spec.skills, skill_registry),
         {:ok, resolved_subagents} <-
           Registries.resolve_subagents(spec.subagents, subagent_registry),
         {:ok, resolved_workflows} <-
           Registries.resolve_workflows(spec.workflows, workflow_registry),
         {:ok, resolved_handoffs} <-
           Registries.resolve_handoffs(spec.handoffs, handoff_registry),
         {:ok, resolved_web} <- Jidoka.Web.normalize_imported(spec.web),
         {:ok, plugin_modules} <- Jidoka.Plugin.resolve_plugin_names(spec.plugins, plugin_registry),
         {:ok, plugin_tool_modules} <- Jidoka.Plugin.plugin_actions(plugin_modules),
         web_tool_modules = Jidoka.Web.tool_modules(resolved_web),
         skill_tool_modules =
           Jidoka.Skill.action_modules(%{refs: skill_refs, load_paths: spec.skill_paths}),
         {:ok, direct_tool_names} <-
           Jidoka.Action.Adapter.action_names(
             direct_tool_modules ++ skill_tool_modules ++ plugin_tool_modules ++ web_tool_modules
           ),
         tool_module_base =
           RuntimeCompiler.generated_tool_module_base(spec, resolved_subagents, resolved_workflows, resolved_handoffs),
         subagent_tool_modules <-
           resolved_subagents
           |> Enum.with_index()
           |> Enum.map(fn {subagent, index} ->
             Jidoka.Subagent.tool_module(tool_module_base, subagent, index)
           end),
         workflow_tool_modules <-
           resolved_workflows
           |> Enum.with_index()
           |> Enum.map(fn {workflow, index} ->
             Jidoka.Workflow.Capability.tool_module(tool_module_base, workflow, index)
           end),
         handoff_tool_modules <-
           resolved_handoffs
           |> Enum.with_index()
           |> Enum.map(fn {handoff, index} ->
             Jidoka.Handoff.Capability.tool_module(tool_module_base, handoff, index)
           end),
         {:ok, hook_modules} <- Registries.resolve_hooks(spec.hooks, hook_registry),
         {:ok, guardrail_modules} <-
           Registries.resolve_guardrails(spec.guardrails, guardrail_registry),
         tool_modules =
           direct_tool_modules ++
             skill_tool_modules ++
             plugin_tool_modules ++
             web_tool_modules ++ subagent_tool_modules ++ workflow_tool_modules ++ handoff_tool_modules,
         :ok <-
           ensure_unique_tool_names(
             direct_tool_names ++
               Enum.map(resolved_subagents, & &1.name) ++
               Enum.map(resolved_workflows, & &1.name) ++
               Enum.map(resolved_handoffs, & &1.name)
           ),
         {:ok, runtime_module} <-
           RuntimeCompiler.ensure_runtime_module(
             spec,
             character_spec,
             tool_modules,
             skill_refs,
             spec.mcp_tools,
             resolved_subagents,
             resolved_workflows,
             resolved_handoffs,
             resolved_web,
             plugin_modules,
             hook_modules,
             guardrail_modules
           ) do
      {:ok,
       %__MODULE__{
         spec: spec,
         character_spec: character_spec,
         runtime_module: runtime_module,
         tool_modules: tool_modules,
         skill_refs: skill_refs,
         mcp_tools: spec.mcp_tools,
         subagents: resolved_subagents,
         workflows: resolved_workflows,
         handoffs: resolved_handoffs,
         web: resolved_web,
         plugin_modules: plugin_modules,
         hook_modules: hook_modules,
         guardrail_modules: guardrail_modules
       }}
    end
  end

  defp ensure_unique_tool_names(tool_names) do
    if Enum.uniq(tool_names) == tool_names do
      :ok
    else
      duplicates =
        tool_names
        |> Enum.frequencies()
        |> Enum.filter(fn {_name, count} -> count > 1 end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      {:error, "duplicate tool names in imported Jidoka agent: #{Enum.join(duplicates, ", ")}"}
    end
  end

  defp resolve_character(nil, _character_registry), do: {:ok, nil}

  defp resolve_character(character, _character_registry) when is_map(character) do
    Jidoka.Character.normalize(nil, character, label: "character")
  end

  defp resolve_character(character, character_registry) when is_binary(character) do
    with {:ok, source} <- Jidoka.Character.resolve_character_name(character, character_registry) do
      Jidoka.Character.normalize(nil, source, label: "character #{inspect(character)}")
    end
  end

  defp build_from_source(source, %{
         tools: tool_registry,
         characters: character_registry,
         skills: skill_registry,
         subagents: subagent_registry,
         workflows: workflow_registry,
         handoffs: handoff_registry,
         plugins: plugin_registry,
         hooks: hook_registry,
         guardrails: guardrail_registry
       }) do
    with {:ok, spec} <-
           Spec.new(source,
             available_tools: tool_registry,
             available_characters: character_registry,
             available_skills: skill_registry,
             available_subagents: subagent_registry,
             available_workflows: workflow_registry,
             available_handoffs: handoff_registry,
             available_plugins: plugin_registry,
             available_hooks: hook_registry,
             available_guardrails: guardrail_registry
           ) do
      build(
        spec,
        tool_registry,
        character_registry,
        skill_registry,
        subagent_registry,
        workflow_registry,
        handoff_registry,
        plugin_registry,
        hook_registry,
        guardrail_registry
      )
    end
  end
end
