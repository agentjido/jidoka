defmodule Jidoka.Agent.ToolSources do
  @moduledoc false

  alias Jidoka.Agent.Dsl.{
    AshResource,
    Browser,
    Handoff,
    MCPTools,
    SkillPath,
    SkillRef,
    Subagent,
    Tool,
    Workflow
  }

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.Handoff, as: HandoffSource
  alias Jidoka.Operation.Source.MCP, as: MCPSource
  alias Jidoka.Operation.Source.Subagent, as: SubagentSource
  alias Jidoka.Operation.Source.Workflow, as: WorkflowSource
  alias Jidoka.Runtime.JidoActions

  @spec entities(module()) :: [struct()]
  def entities(agent_module) when is_atom(agent_module) do
    Spark.Dsl.Extension.get_entities(agent_module, [:tools])
  end

  @spec action_modules(module()) :: [module()]
  def action_modules(agent_module) when is_atom(agent_module) do
    agent_module
    |> entities()
    |> Enum.flat_map(&action_modules_from_entity/1)
  end

  @spec skill_prompt!(module()) :: String.t() | nil
  def skill_prompt!(agent_module) when is_atom(agent_module) do
    operation_from_dsl!(agent_module, [:tools, :skill], fn ->
      case Jidoka.Skill.prompt(skill_refs(agent_module), load_paths: skill_load_paths(agent_module)) do
        {:ok, prompt} -> prompt
        {:error, reason} -> raise ArgumentError, "invalid skill prompt: #{inspect(reason)}"
      end
    end)
  end

  @spec operation_capability(module(), keyword()) ::
          Jidoka.Runtime.Capabilities.operation_capability()
  def operation_capability(agent_module, opts \\ []) when is_atom(agent_module) do
    context = Keyword.get(opts, :context, %{})
    action_capability = JidoActions.operations(action_modules(agent_module), context: context)
    source_capability = source_capability(agent_module, context)

    fn intent, journal ->
      case action_capability.(intent, journal) do
        {:error, {:missing_jido_action, _name}} -> source_capability.(intent, journal)
        result -> result
      end
      |> normalize_missing_action_error()
    end
  end

  @spec operations!(module()) :: [Operation.t()]
  def operations!(agent_module) when is_atom(agent_module) do
    operations =
      agent_module
      |> entities()
      |> Enum.flat_map(&operations_from_entity!(agent_module, &1))

    validate_unique_operations!(agent_module, operations)
    operations
  end

  @spec source_metadata!(module()) :: [map()]
  def source_metadata!(agent_module) when is_atom(agent_module) do
    agent_module
    |> entities()
    |> Enum.flat_map(&source_metadata_from_entity!(agent_module, &1))
  end

  @spec validate!(module()) :: :ok
  def validate!(agent_module) when is_atom(agent_module) do
    _operations = operations!(agent_module)
    :ok
  end

  defp action_modules_from_entity(%Tool{module: action}), do: [action]

  defp action_modules_from_entity(%AshResource{} = ash_resource),
    do: ash_jido_actions(ash_resource)

  defp action_modules_from_entity(%Browser{} = browser) do
    browser
    |> browser_mode!()
    |> Jidoka.Browser.tool_modules()
  end

  defp action_modules_from_entity(%SkillRef{skill: skill}) do
    Jidoka.Skill.action_modules([skill])
  end

  defp action_modules_from_entity(_entity), do: []

  defp operations_from_entity!(agent_module, %Tool{module: action}) do
    [operation_from_action!(agent_module, action, [:tools, :action])]
  end

  defp operations_from_entity!(agent_module, %AshResource{} = ash_resource) do
    generated_actions = ash_jido_actions(ash_resource)

    if generated_actions != [] do
      generated_actions
      |> Enum.map(&operation_from_action!(agent_module, &1, [:tools, :ash_resource]))
      |> Enum.map(&tag_ash_operation(&1, ash_resource))
    else
      []
    end
  end

  defp operations_from_entity!(agent_module, %Browser{} = browser) do
    browser
    |> action_modules_from_entity()
    |> Enum.map(&operation_from_action!(agent_module, &1, [:tools, :browser]))
    |> Enum.map(fn operation ->
      operation_from_dsl!(agent_module, [:tools, :browser], fn ->
        tag_browser_operation(operation, browser)
      end)
    end)
  end

  defp operations_from_entity!(agent_module, %MCPTools{} = mcp_tools) do
    mcp_tools
    |> mcp_source!(agent_module)
    |> Source.operations()
    |> case do
      {:ok, operations} -> operations
      {:error, reason} -> raise ArgumentError, "invalid MCP source: #{inspect(reason)}"
    end
  end

  defp operations_from_entity!(agent_module, %Subagent{} = subagent) do
    subagent
    |> subagent_source!(agent_module)
    |> Source.operations()
    |> case do
      {:ok, operations} -> operations
      {:error, reason} -> raise ArgumentError, "invalid subagent source: #{inspect(reason)}"
    end
  end

  defp operations_from_entity!(agent_module, %Handoff{} = handoff) do
    handoff
    |> handoff_source!(agent_module)
    |> Source.operations()
    |> case do
      {:ok, operations} -> operations
      {:error, reason} -> raise ArgumentError, "invalid handoff source: #{inspect(reason)}"
    end
  end

  defp operations_from_entity!(agent_module, %Workflow{} = workflow) do
    workflow
    |> workflow_source!(agent_module)
    |> Source.operations()
    |> case do
      {:ok, operations} -> operations
      {:error, reason} -> raise ArgumentError, "invalid workflow source: #{inspect(reason)}"
    end
  end

  defp operations_from_entity!(agent_module, %SkillRef{skill: skill}) do
    [skill]
    |> Jidoka.Skill.action_modules()
    |> Enum.map(&operation_from_action!(agent_module, &1, [:tools, :skill]))
    |> Enum.map(fn operation ->
      operation_from_dsl!(agent_module, [:tools, :skill], fn ->
        tag_skill_operation(operation, skill)
      end)
    end)
  end

  defp operations_from_entity!(_agent_module, _entity), do: []

  defp source_metadata_from_entity!(agent_module, %AshResource{} = ash_resource) do
    [
      operation_from_dsl!(agent_module, [:tools, :ash_resource], fn ->
        %{
          "source" => "ash_resource",
          "resource" => inspect(ash_resource.resource),
          "actions" => normalize_name_list!(ash_resource.actions || [], "ash_resource actions"),
          "expanded?" => ash_jido_actions(ash_resource) != []
        }
        |> reject_nil_values()
      end)
    ]
  end

  defp source_metadata_from_entity!(agent_module, %Browser{} = browser) do
    [
      operation_from_dsl!(agent_module, [:tools, :browser], fn ->
        %{
          "source" => "browser",
          "name" => normalize_name!(browser.name, "browser name"),
          "mode" => Atom.to_string(browser_mode!(browser)),
          "allow" => normalize_string_list!(browser.allow || [], "browser allowlist")
        }
      end)
    ]
  end

  defp source_metadata_from_entity!(agent_module, %MCPTools{} = mcp_tools) do
    [
      operation_from_dsl!(agent_module, [:tools, :mcp_tools], fn ->
        source = mcp_source!(mcp_tools, agent_module)

        %{
          "source" => "mcp",
          "endpoint" => metadata_value(source.endpoint),
          "prefix" => source.prefix,
          "required" => source.required,
          "transport" => metadata_value(source.transport),
          "client_info" => source.client_info,
          "protocol_version" => source.protocol_version,
          "capabilities" => source.capabilities,
          "timeouts" => source.timeouts,
          "tools" => Enum.map(source.tools, & &1.name)
        }
        |> reject_nil_values()
      end)
    ]
  end

  defp source_metadata_from_entity!(agent_module, %Subagent{} = subagent) do
    [
      operation_from_dsl!(agent_module, [:tools, :subagent], fn ->
        source = subagent_source!(subagent, agent_module)

        %{
          "source" => "subagent",
          "name" => source.name,
          "agent" => inspect(source.agent),
          "timeout" => source.timeout,
          "forward_context" => inspect(source.forward_context),
          "result" => Atom.to_string(source.result)
        }
      end)
    ]
  end

  defp source_metadata_from_entity!(agent_module, %Handoff{} = handoff) do
    [
      operation_from_dsl!(agent_module, [:tools, :handoff], fn ->
        source = handoff_source!(handoff, agent_module)

        %{
          "source" => "handoff",
          "name" => source.name,
          "agent" => inspect(source.agent),
          "target" => inspect(source.target),
          "forward_context" => inspect(source.forward_context)
        }
      end)
    ]
  end

  defp source_metadata_from_entity!(agent_module, %Workflow{} = workflow) do
    [
      operation_from_dsl!(agent_module, [:tools, :workflow], fn ->
        source = workflow_source!(workflow, agent_module)

        %{
          "source" => "workflow",
          "name" => source.name,
          "workflow" => source.definition.id,
          "module" => inspect(source.workflow),
          "timeout" => source.timeout,
          "async" => source.async,
          "max_concurrency" => source.max_concurrency,
          "forward_context" => inspect(source.forward_context),
          "result" => Atom.to_string(source.result)
        }
        |> reject_nil_values()
      end)
    ]
  end

  defp source_metadata_from_entity!(agent_module, %SkillRef{skill: skill}) do
    operation_from_dsl!(agent_module, [:tools, :skill], fn ->
      case Jidoka.Skill.metadata([skill], load_paths: skill_load_paths(agent_module)) do
        {:ok, metadata} -> metadata
        {:error, reason} -> raise ArgumentError, "invalid skill metadata: #{inspect(reason)}"
      end
    end)
  end

  defp source_metadata_from_entity!(agent_module, %SkillPath{} = skill_path) do
    [
      operation_from_dsl!(agent_module, [:tools, :load_path], fn ->
        %{
          "source" => "skill_path",
          "path" => skill_path.path,
          "expanded_path" => Path.expand(skill_path.path, agent_base_dir(agent_module))
        }
      end)
    ]
  end

  defp source_metadata_from_entity!(_agent_module, _entity), do: []

  defp operation_from_action!(agent_module, action, path) do
    operation_from_dsl!(agent_module, path, fn ->
      with {:module, _module} <- Code.ensure_compiled(action),
           true <- function_exported?(action, :to_tool, 0) do
        JidoActions.operation_from_action!(action)
      else
        {:error, reason} ->
          raise ArgumentError,
                "could not compile action #{inspect(action)}: #{inspect(reason)}"

        false ->
          raise ArgumentError, "#{inspect(action)} must expose `to_tool/0`"
      end
    end)
  end

  defp operation_from_dsl!(agent_module, path, fun) when is_function(fun, 0) do
    fun.()
  rescue
    error in [Spark.Error.DslError] ->
      reraise error, __STACKTRACE__

    exception ->
      reraise Spark.Error.DslError.exception(
                message: Exception.message(exception),
                path: path,
                module: agent_module
              ),
              __STACKTRACE__
  end

  defp tag_ash_operation(
         %Operation{metadata: metadata} = operation,
         %AshResource{} = ash_resource
       ) do
    %Operation{
      operation
      | metadata:
          metadata
          |> Map.merge(normalize_metadata!(ash_resource.metadata))
          |> Map.merge(%{
            "source" => "ash_resource",
            "kind" => "ash_resource",
            "resource" => inspect(ash_resource.resource),
            "action" => operation.name
          })
    }
  end

  defp tag_browser_operation(%Operation{metadata: metadata} = operation, %Browser{} = browser) do
    browser_name = normalize_name!(browser.name, "browser name")
    mode = browser_mode!(browser)

    %Operation{
      operation
      | description: browser.description || operation.description,
        idempotency: browser.idempotency || operation.idempotency,
        metadata:
          metadata
          |> Map.merge(normalize_metadata!(browser.metadata))
          |> Map.merge(%{
            "source" => "browser",
            "kind" => "browser",
            "browser" => browser_name,
            "mode" => Atom.to_string(mode),
            "allow" => normalize_string_list!(browser.allow || [], "browser allowlist")
          })
    }
  end

  defp tag_skill_operation(%Operation{metadata: metadata} = operation, skill) do
    skill_name = skill_name(skill)

    %Operation{
      operation
      | metadata:
          metadata
          |> Map.merge(%{
            "source" => "skill",
            "kind" => "skill",
            "skill" => skill_name,
            "action" => operation.name
          })
    }
  end

  defp operation_sources!(agent_module) do
    agent_module
    |> entities()
    |> Enum.flat_map(fn
      %MCPTools{} = mcp_tools -> [mcp_source!(mcp_tools, agent_module)]
      %Subagent{} = subagent -> [subagent_source!(subagent, agent_module)]
      %Handoff{} = handoff -> [handoff_source!(handoff, agent_module)]
      %Workflow{} = workflow -> [workflow_source!(workflow, agent_module)]
      _entity -> []
    end)
  end

  defp mcp_source!(%MCPTools{} = mcp_tools, agent_module) do
    operation_from_dsl!(agent_module, [:tools, :mcp_tools], fn ->
      MCPSource.new!(
        endpoint: mcp_tools.endpoint,
        prefix: mcp_tools.prefix,
        tools: mcp_tools.tools || [],
        required: mcp_tools.required || false,
        transport: mcp_tools.transport,
        client_info: mcp_tools.client_info,
        protocol_version: mcp_tools.protocol_version,
        capabilities: mcp_tools.capabilities || %{},
        timeouts: mcp_tools.timeouts || %{},
        timeout: mcp_tools.timeout,
        description: mcp_tools.description,
        idempotency: mcp_tools.idempotency || :idempotent,
        metadata: mcp_tools.metadata || %{}
      )
    end)
  end

  defp subagent_source!(%Subagent{} = subagent, agent_module) do
    operation_from_dsl!(agent_module, [:tools, :subagent], fn ->
      SubagentSource.new!(
        agent: subagent.agent,
        as: subagent.as,
        description: subagent.description,
        timeout: subagent.timeout || 30_000,
        forward_context: subagent.forward_context || :public,
        result: subagent.result || :structured,
        metadata: subagent.metadata || %{}
      )
    end)
  end

  defp handoff_source!(%Handoff{} = handoff, agent_module) do
    operation_from_dsl!(agent_module, [:tools, :handoff], fn ->
      HandoffSource.new!(
        agent: handoff.agent,
        as: handoff.as,
        description: handoff.description,
        target: handoff.target || :auto,
        forward_context: handoff.forward_context || :public,
        metadata: handoff.metadata || %{}
      )
    end)
  end

  defp workflow_source!(%Workflow{} = workflow, agent_module) do
    operation_from_dsl!(agent_module, [:tools, :workflow], fn ->
      WorkflowSource.new!(
        workflow: workflow.workflow,
        as: workflow.as,
        description: workflow.description,
        timeout: workflow.timeout || 30_000,
        async: workflow.async || false,
        max_concurrency: workflow.max_concurrency,
        forward_context: workflow.forward_context || :public,
        result: workflow.result || :output,
        idempotency: workflow.idempotency || :idempotent,
        metadata: workflow.metadata || %{}
      )
    end)
  end

  defp source_capability(agent_module, context) do
    case Source.compile(operation_sources!(agent_module), context: context) do
      {:ok, %{capability: capability}} ->
        capability

      {:error, reason} ->
        fn _intent, _journal -> {:error, reason} end
    end
  end

  defp skill_refs(agent_module) do
    agent_module
    |> entities()
    |> Enum.flat_map(fn
      %SkillRef{skill: skill} -> [skill]
      _entity -> []
    end)
  end

  defp skill_load_paths(agent_module) do
    load_paths =
      agent_module
      |> entities()
      |> Enum.flat_map(fn
        %SkillPath{path: path} -> [path]
        _entity -> []
      end)

    Jidoka.Skill.normalize_load_paths(load_paths, agent_base_dir(agent_module))
  end

  defp normalize_missing_action_error({:error, {:missing_jido_action, name}}),
    do: {:error, {:missing_operation_handler, name}}

  defp normalize_missing_action_error(result), do: result

  defp ash_jido_actions(%AshResource{} = ash_resource) do
    with module <- ash_jido_tools_module(),
         {:module, module} <- Code.ensure_compiled(module),
         actions when is_list(actions) <- apply(module, :actions, [ash_resource.resource]) do
      maybe_filter_ash_jido_actions(actions, ash_resource.actions || [])
    else
      _reason -> []
    end
  rescue
    _exception -> []
  end

  defp ash_jido_tools_module do
    Application.get_env(:jidoka, :ash_jido_tools, AshJido.Tools)
  end

  defp maybe_filter_ash_jido_actions(actions, requested_actions)
       when requested_actions in [nil, []],
       do: actions

  defp maybe_filter_ash_jido_actions(actions, requested_actions) do
    requested = MapSet.new(normalize_name_list!(requested_actions, "ash_resource actions"))

    Enum.filter(actions, fn action ->
      action_tool_name(action) in requested or action_module_name(action) in requested
    end)
  end

  defp action_tool_name(action) do
    case action.to_tool() do
      %{name: name} -> to_string(name)
      _tool -> nil
    end
  rescue
    _exception -> nil
  end

  defp action_module_name(action) do
    action
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp skill_name(skill) when is_atom(skill) do
    skill
    |> Jido.AI.Skill.manifest()
    |> Map.get(:name)
  rescue
    _exception -> inspect(skill)
  end

  defp skill_name(skill) when is_binary(skill), do: String.trim(skill)

  defp validate_unique_operations!(agent_module, operations) do
    operations
    |> Enum.reduce_while(MapSet.new(), fn %Operation{name: name}, seen ->
      if MapSet.member?(seen, name) do
        {:halt, {:duplicate, name}}
      else
        {:cont, MapSet.put(seen, name)}
      end
    end)
    |> case do
      %MapSet{} ->
        :ok

      {:duplicate, name} ->
        raise Spark.Error.DslError.exception(
                message: "tool #{inspect(name)} is defined more than once",
                path: [:tools],
                module: agent_module
              )
    end
  end

  defp browser_mode!(%Browser{} = browser) do
    case Jidoka.Browser.normalize_mode(browser.mode || :read_only) do
      {:ok, mode} -> mode
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp normalize_name_list!(nil, _label), do: []

  defp normalize_name_list!(values, label) when is_list(values) do
    Enum.map(values, &normalize_name!(&1, label))
  end

  defp normalize_name_list!(value, label), do: [normalize_name!(value, label)]

  defp normalize_string_list!(nil, _label), do: []

  defp normalize_string_list!(values, label) when is_list(values) do
    Enum.map(values, &normalize_string!(&1, label))
  end

  defp normalize_string_list!(value, label), do: [normalize_string!(value, label)]

  defp normalize_name!(value, label) when is_atom(value) and not is_nil(value) do
    value |> Atom.to_string() |> normalize_name!(label)
  end

  defp normalize_name!(value, label) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, value) do
      value
    else
      raise ArgumentError, "#{label} must be lower snake case, got: #{inspect(value)}"
    end
  end

  defp normalize_name!(value, label) do
    raise ArgumentError, "#{label} must be an atom or string, got: #{inspect(value)}"
  end

  defp normalize_string!(value, _label) when is_atom(value) and not is_nil(value) do
    Atom.to_string(value)
  end

  defp normalize_string!(value, label) when is_binary(value) do
    case String.trim(value) do
      "" -> raise ArgumentError, "#{label} cannot include empty strings"
      value -> value
    end
  end

  defp normalize_string!(value, label) do
    raise ArgumentError, "#{label} entries must be atoms or strings, got: #{inspect(value)}"
  end

  defp normalize_metadata!(nil), do: %{}
  defp normalize_metadata!(metadata) when is_map(metadata), do: metadata

  defp normalize_metadata!(metadata) do
    raise ArgumentError, "tool metadata must be a map, got: #{inspect(metadata)}"
  end

  defp metadata_value(nil), do: nil
  defp metadata_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp metadata_value(value) when is_binary(value), do: value
  defp metadata_value(value), do: inspect(value)

  defp agent_base_dir(agent_module) do
    source =
      agent_module.module_info(:compile)
      |> Keyword.get(:source)

    source
    |> List.to_string()
    |> Path.dirname()
  rescue
    _exception -> File.cwd!()
  end

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
