defmodule Jidoka.Plugin do
  @moduledoc """
  Jidoka-friendly plugin authoring surface backed by `Jido.Plugin`.

  This first pass keeps the plugin surface intentionally narrow:

  - publish a stable plugin name
  - register zero or more action-backed tools
  - compile down to a plain `Jido.Plugin`

  Jidoka plugins are the main extension point for adding capability around a Jidoka
  agent without growing the base DSL too quickly.
  """

  @required_functions [
    {:name, 0},
    {:state_key, 0},
    {:actions, 0},
    {:plugin_spec, 1}
  ]

  @typedoc """
  A published Jidoka plugin name.
  """
  @type name :: String.t()

  @typedoc """
  A registry of published Jidoka plugin names to plugin modules.
  """
  @type registry :: %{required(name()) => module()}

  @doc """
  Defines a Jidoka plugin module backed by `Jido.Plugin`.
  """
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts \\ []) do
    module_name =
      __CALLER__.module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    expanded_tools =
      opts
      |> Keyword.get(:tools, [])
      |> Enum.map(fn
        {:__aliases__, _, _} = alias_ast -> Macro.expand(alias_ast, __CALLER__)
        mod when is_atom(mod) -> mod
      end)

    defaults = [
      name: module_name,
      state_key: String.to_atom(module_name),
      description: "Jidoka plugin #{module_name}",
      actions: [],
      schema: Zoi.object(%{}) |> Zoi.default(%{})
    ]

    forwarded_opts =
      defaults
      |> Keyword.merge(Keyword.delete(opts, :tools))
      |> then(fn merged ->
        case Keyword.fetch(opts, :tools) do
          {:ok, _tools} -> Keyword.put(merged, :actions, expanded_tools)
          :error -> merged
        end
      end)

    quote location: :keep do
      use Jido.Plugin, unquote(Macro.escape(forwarded_opts))
      @after_compile Jidoka.Plugin
    end
  end

  @doc false
  def __after_compile__(env, _bytecode) do
    case validate_plugin_module(env.module) do
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
  Validates that a module behaves like a Jidoka plugin.
  """
  @spec validate_plugin_module(module()) :: :ok | {:error, String.t()}
  def validate_plugin_module(module) when is_atom(module) do
    cond do
      match?({:error, _}, Code.ensure_compiled(module)) ->
        {:error, "plugin #{inspect(module)} could not be loaded"}

      missing = missing_functions(module) ->
        {:error, "plugin #{inspect(module)} is not a valid Jidoka plugin; missing #{Enum.join(missing, ", ")}"}

      true ->
        with {:ok, _name} <- plugin_name(module),
             {:ok, _actions} <- plugin_actions(module) do
          :ok
        end
    end
  end

  def validate_plugin_module(other),
    do: {:error, "plugin entries must be modules, got: #{inspect(other)}"}

  @doc """
  Returns the published name for a validated Jidoka plugin module.
  """
  @spec plugin_name(module()) :: {:ok, name()} | {:error, String.t()}
  def plugin_name(module) when is_atom(module) do
    with :ok <- ensure_compiled_plugin(module),
         name when is_binary(name) <- module.name(),
         trimmed <- String.trim(name),
         true <- trimmed != "" do
      {:ok, trimmed}
    else
      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, "plugin #{inspect(module)} must publish a non-empty string name"}
    end
  end

  def plugin_name(other),
    do: {:error, "plugin entries must be modules, got: #{inspect(other)}"}

  @doc """
  Returns the published names for a list of Jidoka plugin modules.
  """
  @spec plugin_names([module()]) :: {:ok, [name()]} | {:error, String.t()}
  def plugin_names(modules) when is_list(modules) do
    modules
    |> Enum.reduce_while({:ok, []}, fn module, {:ok, acc} ->
      case plugin_name(module) do
        {:ok, name} -> {:cont, {:ok, acc ++ [name]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, names} ->
        if Enum.uniq(names) == names do
          {:ok, names}
        else
          {:error, "plugin names must be unique within a Jidoka agent"}
        end

      other ->
        other
    end
  end

  @doc """
  Returns the published action-backed tools for a validated plugin module or modules.
  """
  @spec plugin_actions(module() | [module()]) :: {:ok, [module()]} | {:error, String.t()}
  def plugin_actions(module) when is_atom(module) do
    with :ok <- ensure_compiled_plugin(module),
         actions when is_list(actions) <- module.actions(),
         {:ok, _action_names} <- Jidoka.Action.Adapter.action_names(actions) do
      {:ok, actions}
    else
      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, "plugin #{inspect(module)} must expose a list of action-backed tools"}
    end
  end

  def plugin_actions(modules) when is_list(modules) do
    modules
    |> Enum.reduce_while({:ok, []}, fn module, {:ok, acc} ->
      case plugin_actions(module) do
        {:ok, actions} -> {:cont, {:ok, acc ++ actions}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def plugin_actions(other),
    do: {:error, "plugin entries must be modules or lists of modules, got: #{inspect(other)}"}

  @doc """
  Normalizes an available-plugins registry for imported agent specs.

  Accepts either:

  - a list of Jidoka plugin modules
  - a map of published plugin name to plugin module
  """
  @spec normalize_available_plugins([module()] | %{required(name()) => module()}) ::
          {:ok, registry()} | {:error, String.t()}
  def normalize_available_plugins(modules) when is_list(modules) do
    modules
    |> Enum.reduce_while({:ok, %{}}, fn module, {:ok, acc} ->
      with {:ok, name} <- plugin_name(module),
           :ok <- ensure_unique_registry_name(name, acc) do
        {:cont, {:ok, Map.put(acc, name, module)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_available_plugins(registry) when is_map(registry) do
    registry
    |> Enum.reduce_while({:ok, %{}}, fn {name, module}, {:ok, acc} ->
      with true <- is_binary(name) or {:error, "plugin registry keys must be strings"},
           trimmed <- String.trim(name),
           true <- trimmed != "" or {:error, "plugin registry keys must not be empty"},
           {:ok, published_name} <- plugin_name(module),
           true <-
             trimmed == published_name or
               {:error,
                "plugin registry key #{inspect(trimmed)} must match published plugin name #{inspect(published_name)}"},
           :ok <- ensure_unique_registry_name(trimmed, acc) do
        {:cont, {:ok, Map.put(acc, trimmed, module)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_available_plugins(other),
    do:
      {:error,
       "available_plugins must be a list of Jidoka plugin modules or a map of name => module, got: #{inspect(other)}"}

  @doc """
  Resolves a list of published plugin names against a normalized plugin registry.
  """
  @spec resolve_plugin_names([name()], registry()) :: {:ok, [module()]} | {:error, String.t()}
  def resolve_plugin_names(names, registry) when is_list(names) and is_map(registry) do
    names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case Map.fetch(registry, name) do
        {:ok, module} -> {:cont, {:ok, acc ++ [module]}}
        :error -> {:halt, {:error, "unknown plugin #{inspect(name)}"}}
      end
    end)
  end

  def resolve_plugin_names(_names, _registry),
    do: {:error, "plugin names must be a list and registry must be a map"}

  defp ensure_compiled_plugin(module) do
    cond do
      match?({:error, _}, Code.ensure_compiled(module)) ->
        {:error, "plugin #{inspect(module)} could not be loaded"}

      missing = missing_functions(module) ->
        {:error, "plugin #{inspect(module)} is not a valid Jidoka plugin; missing #{Enum.join(missing, ", ")}"}

      true ->
        :ok
    end
  end

  defp missing_functions(module) do
    @required_functions
    |> Enum.reject(fn {function, arity} -> function_exported?(module, function, arity) end)
    |> Enum.map(fn {function, arity} -> "#{function}/#{arity}" end)
    |> case do
      [] -> nil
      missing -> missing
    end
  end

  defp ensure_unique_registry_name(name, registry) do
    if Map.has_key?(registry, name) do
      {:error, "duplicate plugin name #{inspect(name)} in available_plugins registry"}
    else
      :ok
    end
  end
end
