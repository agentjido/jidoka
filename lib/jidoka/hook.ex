defmodule Jidoka.Hook do
  @moduledoc """
  Defines reusable lifecycle callbacks for Jidoka agents.

  Hooks are for lifecycle integration points such as preparing a turn, observing
  a completed turn, or reacting to an interrupt. They are intentionally separate
  from policy controls: use `Jidoka.Control` for input, operation, result, and
  human-in-the-loop decisions.
  """

  @required_functions [
    {:name, 0},
    {:call, 1}
  ]

  @type name :: String.t()
  @type registry :: %{required(name()) => module()}

  @callback name() :: name()
  @callback call(term()) :: term()

  @doc """
  Defines a reusable Jidoka hook module.
  """
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts \\ []) do
    module_name =
      __CALLER__.module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    defaults = [
      name: module_name
    ]

    quote location: :keep do
      @behaviour Jidoka.Hook

      @hook_name unquote(Keyword.get(Keyword.merge(defaults, opts), :name))

      @spec name() :: String.t()
      def name, do: @hook_name

      @after_compile Jidoka.Hook
    end
  end

  @doc false
  def __after_compile__(env, _bytecode) do
    case validate_hook_module(env.module) do
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
  Validates that a module implements the Jidoka hook contract.
  """
  @spec validate_hook_module(module()) :: :ok | {:error, String.t()}
  def validate_hook_module(module) when is_atom(module) do
    cond do
      match?({:error, _}, Code.ensure_compiled(module)) ->
        {:error, "hook #{inspect(module)} could not be loaded"}

      missing = missing_functions(module) ->
        {:error, "hook #{inspect(module)} is not a valid Jidoka hook; missing #{Enum.join(missing, ", ")}"}

      true ->
        hook_name(module)
        |> case do
          {:ok, _name} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def validate_hook_module(other),
    do: {:error, "hook entries must be modules, got: #{inspect(other)}"}

  @doc """
  Returns the published name for a validated hook module.
  """
  @spec hook_name(module()) :: {:ok, name()} | {:error, String.t()}
  def hook_name(module) when is_atom(module) do
    with :ok <- ensure_compiled_hook(module),
         name when is_binary(name) <- module.name(),
         trimmed <- String.trim(name),
         true <- trimmed != "" do
      {:ok, trimmed}
    else
      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, "hook #{inspect(module)} must publish a non-empty string name"}
    end
  end

  def hook_name(other),
    do: {:error, "hook entries must be modules, got: #{inspect(other)}"}

  @doc """
  Returns the published names for a list of hook modules.
  """
  @spec hook_names([module()]) :: {:ok, [name()]} | {:error, String.t()}
  def hook_names(modules) when is_list(modules) do
    modules
    |> Enum.reduce_while({:ok, []}, fn module, {:ok, acc} ->
      case hook_name(module) do
        {:ok, name} -> {:cont, {:ok, acc ++ [name]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, names} -> {:ok, names}
      other -> other
    end
  end

  @doc """
  Normalizes an available-hooks registry for imported agent specs.
  """
  @spec normalize_available_hooks([module()] | %{required(name()) => module()}) ::
          {:ok, registry()} | {:error, String.t()}
  def normalize_available_hooks(modules) when is_list(modules) do
    modules
    |> Enum.reduce_while({:ok, %{}}, fn module, {:ok, acc} ->
      with {:ok, name} <- hook_name(module),
           :ok <- ensure_unique_registry_name(name, acc) do
        {:cont, {:ok, Map.put(acc, name, module)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_available_hooks(registry) when is_map(registry) do
    registry
    |> Enum.reduce_while({:ok, %{}}, fn {name, module}, {:ok, acc} ->
      with true <- is_binary(name) or {:error, "hook registry keys must be strings"},
           trimmed <- String.trim(name),
           true <- trimmed != "" or {:error, "hook registry keys must not be empty"},
           {:ok, published_name} <- hook_name(module),
           true <-
             trimmed == published_name or
               {:error,
                "hook registry key #{inspect(trimmed)} must match published hook name #{inspect(published_name)}"},
           :ok <- ensure_unique_registry_name(trimmed, acc) do
        {:cont, {:ok, Map.put(acc, trimmed, module)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_available_hooks(other),
    do:
      {:error,
       "available_hooks must be a list of Jidoka hook modules or a map of name => module, got: #{inspect(other)}"}

  @doc """
  Resolves imported hook names through a normalized hook registry.
  """
  @spec resolve_hook_names([name()], registry()) :: {:ok, [module()]} | {:error, String.t()}
  def resolve_hook_names(names, registry) when is_list(names) and is_map(registry) do
    names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case Map.fetch(registry, name) do
        {:ok, module} -> {:cont, {:ok, acc ++ [module]}}
        :error -> {:halt, {:error, "unknown hook #{inspect(name)}"}}
      end
    end)
  end

  def resolve_hook_names(_names, _registry),
    do: {:error, "hook names must be a list and registry must be a map"}

  defp ensure_compiled_hook(module) do
    cond do
      match?({:error, _}, Code.ensure_compiled(module)) ->
        {:error, "hook #{inspect(module)} could not be loaded"}

      missing = missing_functions(module) ->
        {:error, "hook #{inspect(module)} is not a valid Jidoka hook; missing #{Enum.join(missing, ", ")}"}

      true ->
        :ok
    end
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

  defp ensure_unique_registry_name(name, acc) do
    if Map.has_key?(acc, name) do
      {:error, "hook names must be unique within a Jidoka hook registry"}
    else
      :ok
    end
  end
end
