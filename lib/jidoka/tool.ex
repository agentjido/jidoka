defmodule Jidoka.Tool do
  @moduledoc false

  @required_functions [
    {:run, 2},
    {:name, 0},
    {:schema, 0},
    {:output_schema, 0},
    {:to_tool, 0}
  ]

  @typedoc """
  A published Jidoka tool name.
  """
  @type name :: String.t()

  @typedoc """
  A registry of published tool names to tool modules.
  """
  @type registry :: %{required(name()) => module()}

  @doc """
  Defines a Jidoka tool module backed by `Jido.Action`.
  """
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts \\ []) do
    module_name =
      __CALLER__.module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    defaults = [
      name: module_name,
      description: "Jidoka action #{module_name}"
    ]

    quote location: :keep do
      use Jido.Action, unquote(Keyword.merge(defaults, opts))
      @after_compile Jidoka.Tool
    end
  end

  @doc false
  def __after_compile__(env, _bytecode) do
    case validate_tool_module(env.module) do
      :ok ->
        :ok

      {:error, message} ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: message
    end
  end

  @doc """
  Validates that a module behaves like a generic Jido action-backed tool.
  """
  @spec validate_action_module(module()) :: :ok | {:error, String.t()}
  def validate_action_module(module) when is_atom(module) do
    cond do
      match?({:error, _}, Code.ensure_compiled(module)) ->
        {:error, "action #{inspect(module)} could not be loaded"}

      missing = missing_functions(module) ->
        {:error, "action #{inspect(module)} is not a valid action-backed module; missing #{Enum.join(missing, ", ")}"}

      true ->
        validate_tool_name(module)
    end
  end

  def validate_action_module(other),
    do: {:error, "action entries must be modules, got: #{inspect(other)}"}

  @doc """
  Validates that a module behaves like a Jidoka tool.
  """
  @spec validate_tool_module(module()) :: :ok | {:error, String.t()}
  def validate_tool_module(module) when is_atom(module) do
    with :ok <- validate_action_module(module),
         :ok <- validate_tool_schema(module, :schema),
         :ok <- validate_tool_schema(module, :output_schema) do
      :ok
    else
      {:error, message} ->
        if String.contains?(message, "valid action-backed module") do
          {:error, String.replace(message, "valid action-backed module", "valid Jidoka action")}
        else
          {:error, message}
        end
    end
  end

  def validate_tool_module(other),
    do: {:error, "action entries must be modules, got: #{inspect(other)}"}

  @doc """
  Returns the published name for a validated action-backed tool module.
  """
  @spec action_name(module()) :: {:ok, name()} | {:error, String.t()}
  def action_name(module) do
    with :ok <- validate_action_module(module),
         name when is_binary(name) <- module.name(),
         trimmed <- String.trim(name),
         true <- trimmed != "" do
      {:ok, trimmed}
    else
      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, "action #{inspect(module)} must publish a non-empty string name"}
    end
  end

  @doc """
  Returns the published names for a list of validated action-backed tool modules.
  """
  @spec action_names([module()]) :: {:ok, [name()]} | {:error, String.t()}
  def action_names(modules) when is_list(modules) do
    modules
    |> Enum.reduce_while({:ok, []}, fn module, {:ok, acc} ->
      case action_name(module) do
        {:ok, name} -> {:cont, {:ok, acc ++ [name]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, names} ->
        if Enum.uniq(names) == names do
          {:ok, names}
        else
          {:error, duplicate_operation_names_message(names)}
        end

      other ->
        other
    end
  end

  @doc """
  Returns the published tool name for a validated tool module.
  """
  @spec tool_name(module()) :: {:ok, name()} | {:error, String.t()}
  def tool_name(module) do
    with :ok <- validate_tool_module(module),
         name when is_binary(name) <- module.name(),
         trimmed <- String.trim(name),
         true <- trimmed != "" do
      {:ok, trimmed}
    else
      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, "action #{inspect(module)} must publish a non-empty string name"}
    end
  end

  @doc """
  Returns the published names for a list of validated tool modules.
  """
  @spec tool_names([module()]) :: {:ok, [name()]} | {:error, String.t()}
  def tool_names(modules) when is_list(modules) do
    modules
    |> Enum.reduce_while({:ok, []}, fn module, {:ok, acc} ->
      case tool_name(module) do
        {:ok, name} -> {:cont, {:ok, acc ++ [name]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, names} ->
        if Enum.uniq(names) == names do
          {:ok, names}
        else
          {:error, duplicate_operation_names_message(names)}
        end

      other ->
        other
    end
  end

  @doc """
  Normalizes an available-tools registry for imported agent specs.

  Accepts either:

  - a list of action-backed tool modules
  - a map of published tool name to action-backed tool module
  """
  @spec normalize_available_tools([module()] | %{required(name()) => module()}) ::
          {:ok, registry()} | {:error, String.t()}
  def normalize_available_tools(modules) when is_list(modules) do
    modules
    |> Enum.reduce_while({:ok, %{}}, fn module, {:ok, acc} ->
      with {:ok, name} <- action_name(module),
           :ok <- ensure_unique_registry_name(name, acc) do
        {:cont, {:ok, Map.put(acc, name, module)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_available_tools(registry) when is_map(registry) do
    registry
    |> Enum.reduce_while({:ok, %{}}, fn {name, module}, {:ok, acc} ->
      with true <- is_binary(name) or {:error, "tool registry keys must be strings"},
           trimmed <- String.trim(name),
           true <- trimmed != "" or {:error, "tool registry keys must not be empty"},
           {:ok, published_name} <- action_name(module),
           true <-
             trimmed == published_name or
               {:error,
                "tool registry key #{inspect(trimmed)} must match published tool name #{inspect(published_name)}"},
           :ok <- ensure_unique_registry_name(trimmed, acc) do
        {:cont, {:ok, Map.put(acc, trimmed, module)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_available_tools(other),
    do:
      {:error,
       "available_tools must be a list of action-backed tool modules or a map of name => module, got: #{inspect(other)}"}

  @doc """
  Resolves a list of published tool names against a normalized tool registry.
  """
  @spec resolve_tool_names([name()], registry()) :: {:ok, [module()]} | {:error, String.t()}
  def resolve_tool_names(names, registry) when is_list(names) and is_map(registry) do
    names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case Map.fetch(registry, name) do
        {:ok, module} -> {:cont, {:ok, acc ++ [module]}}
        :error -> {:halt, {:error, "unknown tool #{inspect(name)}"}}
      end
    end)
  end

  defp missing_functions(module) do
    @required_functions
    |> Enum.reject(fn {name, arity} -> function_exported?(module, name, arity) end)
    |> Enum.map(fn {name, arity} -> "#{name}/#{arity}" end)
    |> case do
      [] -> nil
      missing -> missing
    end
  end

  defp validate_tool_name(module) do
    case module.name() do
      name when is_binary(name) ->
        if String.trim(name) == "" do
          {:error, "action #{inspect(module)} must publish a non-empty string name"}
        else
          :ok
        end

      other ->
        {:error, "action #{inspect(module)} must publish a string name via name/0, got: #{inspect(other)}"}
    end
  rescue
    error ->
      {:error, "action #{inspect(module)} failed while reading name/0: #{Exception.message(error)}"}
  end

  defp validate_tool_schema(module, function_name) do
    schema = apply(module, function_name, [])

    cond do
      schema in [[], nil] ->
        :ok

      zoi_schema?(schema) ->
        :ok

      true ->
        {:error,
         "action #{inspect(module)} must use a Zoi schema for #{function_name}/0; NimbleOptions and raw JSON Schema maps are not supported in Jidoka.Action"}
    end
  rescue
    error ->
      {:error, "action #{inspect(module)} failed while reading #{function_name}/0: #{Exception.message(error)}"}
  end

  defp zoi_schema?(schema) do
    is_struct(schema) and Zoi.Type.impl_for(schema) != nil
  rescue
    _ -> false
  end

  defp ensure_unique_registry_name(name, acc) do
    if Map.has_key?(acc, name) do
      {:error, "duplicate tool name #{inspect(name)} in available_tools"}
    else
      :ok
    end
  end

  defp duplicate_operation_names_message(names) do
    duplicates =
      names
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map_join(", ", fn {name, _count} -> name end)

    "duplicate operation names in Jidoka agent: #{duplicates}"
  end
end
