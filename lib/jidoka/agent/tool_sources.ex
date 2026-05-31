defmodule Jidoka.Agent.ToolSources do
  @moduledoc false

  alias Jidoka.Agent.Dsl.{AshResource, Browser, Catalog, Tool}
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.Catalog, as: CatalogSource
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

  @spec operation_capability(module(), keyword()) ::
          Jidoka.Runtime.Capabilities.operation_capability()
  def operation_capability(agent_module, opts \\ []) when is_atom(agent_module) do
    context = Keyword.get(opts, :context, %{})
    action_capability = JidoActions.operations(action_modules(agent_module), context: context)
    source_capability = source_capability(agent_module)

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

  defp action_modules_from_entity(_entity), do: []

  defp operations_from_entity!(agent_module, %Tool{module: action}) do
    [operation_from_action!(agent_module, action, [:tools, :action])]
  end

  defp operations_from_entity!(agent_module, %AshResource{} = ash_resource) do
    generated_actions = ash_jido_actions(ash_resource)

    cond do
      generated_actions != [] ->
        generated_actions
        |> Enum.map(&operation_from_action!(agent_module, &1, [:tools, :ash_resource]))
        |> Enum.map(&tag_ash_operation(&1, ash_resource))

      true ->
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

  defp operations_from_entity!(agent_module, %Catalog{} = catalog) do
    catalog
    |> catalog_source!(agent_module)
    |> Source.operations()
    |> case do
      {:ok, operations} -> operations
      {:error, reason} -> raise ArgumentError, "invalid catalog source: #{inspect(reason)}"
    end
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

  defp source_metadata_from_entity!(agent_module, %Catalog{} = catalog) do
    [
      operation_from_dsl!(agent_module, [:tools, :catalog], fn ->
        source = catalog_source!(catalog, agent_module)

        %{
          "source" => "catalog",
          "name" => source.name,
          "via" => metadata_value(source.via),
          "providers" => source.providers,
          "only" => source.only,
          "except" => source.except,
          "max_results" => source.max_results
        }
        |> reject_nil_values()
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
      raise Spark.Error.DslError.exception(
              message: Exception.message(exception),
              path: path,
              module: agent_module
            )
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

  defp catalog_sources!(agent_module) do
    agent_module
    |> entities()
    |> Enum.flat_map(fn
      %Catalog{} = catalog -> [catalog_source!(catalog, agent_module)]
      _entity -> []
    end)
  end

  defp catalog_source!(%Catalog{} = catalog, agent_module) do
    operation_from_dsl!(agent_module, [:tools, :catalog], fn ->
      CatalogSource.new!(
        name: catalog.name,
        via: catalog.via || :jido_discovery,
        providers: catalog.providers || [],
        only: catalog.only || [],
        except: catalog.except || [],
        max_results: catalog.max_results,
        description: catalog.description,
        idempotency: catalog.idempotency || :idempotent,
        metadata: catalog.metadata || %{}
      )
    end)
  end

  defp source_capability(agent_module) do
    case Source.compile(catalog_sources!(agent_module)) do
      {:ok, %{capability: capability}} ->
        capability

      {:error, reason} ->
        fn _intent, _journal -> {:error, reason} end
    end
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

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
