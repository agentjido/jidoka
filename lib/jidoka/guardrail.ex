defmodule Jidoka.Guardrail do
  @moduledoc false

  @required_functions [
    {:name, 0},
    {:call, 1}
  ]

  @type name :: String.t()
  @type registry :: %{required(name()) => module()}

  @callback name() :: name()
  @callback call(term()) :: term()

  @doc """
  Defines a reusable Jidoka guardrail module.
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
      @behaviour Jidoka.Guardrail

      @guardrail_name unquote(Keyword.get(Keyword.merge(defaults, opts), :name))

      @spec name() :: String.t()
      def name, do: @guardrail_name

      @after_compile Jidoka.Guardrail
    end
  end

  @doc false
  def __after_compile__(env, _bytecode) do
    case validate_guardrail_module(env.module) do
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
  Validates that a module implements the Jidoka guardrail contract.
  """
  @spec validate_guardrail_module(module()) :: :ok | {:error, String.t()}
  def validate_guardrail_module(module) when is_atom(module) do
    cond do
      match?({:error, _}, Code.ensure_compiled(module)) ->
        {:error, "guardrail #{inspect(module)} could not be loaded"}

      missing = missing_functions(module) ->
        {:error, "guardrail #{inspect(module)} is not a valid Jidoka guardrail; missing #{Enum.join(missing, ", ")}"}

      true ->
        guardrail_name(module)
        |> case do
          {:ok, _name} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def validate_guardrail_module(other),
    do: {:error, "guardrail entries must be modules, got: #{inspect(other)}"}

  @doc """
  Returns the published name for a validated guardrail module.
  """
  @spec guardrail_name(module()) :: {:ok, name()} | {:error, String.t()}
  def guardrail_name(module) when is_atom(module) do
    with :ok <- ensure_compiled_guardrail(module),
         name when is_binary(name) <- module.name(),
         trimmed <- String.trim(name),
         true <- trimmed != "" do
      {:ok, trimmed}
    else
      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, "guardrail #{inspect(module)} must publish a non-empty string name"}
    end
  end

  def guardrail_name(other),
    do: {:error, "guardrail entries must be modules, got: #{inspect(other)}"}

  @doc """
  Returns the published names for a list of guardrail modules.
  """
  @spec guardrail_names([module()]) :: {:ok, [name()]} | {:error, String.t()}
  def guardrail_names(modules) when is_list(modules) do
    modules
    |> Enum.reduce_while({:ok, []}, fn module, {:ok, acc} ->
      case guardrail_name(module) do
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
  Normalizes an available-guardrails registry for imported agent specs.
  """
  @spec normalize_available_guardrails([module()] | %{required(name()) => module()}) ::
          {:ok, registry()} | {:error, String.t()}
  def normalize_available_guardrails(modules) when is_list(modules) do
    modules
    |> Enum.reduce_while({:ok, %{}}, fn module, {:ok, acc} ->
      with {:ok, name} <- guardrail_name(module),
           :ok <- ensure_unique_registry_name(name, acc) do
        {:cont, {:ok, Map.put(acc, name, module)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_available_guardrails(registry) when is_map(registry) do
    registry
    |> Enum.reduce_while({:ok, %{}}, fn {name, module}, {:ok, acc} ->
      with true <- is_binary(name) or {:error, "guardrail registry keys must be strings"},
           trimmed <- String.trim(name),
           true <- trimmed != "" or {:error, "guardrail registry keys must not be empty"},
           {:ok, published_name} <- guardrail_name(module),
           true <-
             trimmed == published_name or
               {:error,
                "guardrail registry key #{inspect(trimmed)} must match published guardrail name #{inspect(published_name)}"},
           :ok <- ensure_unique_registry_name(trimmed, acc) do
        {:cont, {:ok, Map.put(acc, trimmed, module)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_available_guardrails(other),
    do:
      {:error,
       "available_guardrails must be a list of Jidoka guardrail modules or a map of name => module, got: #{inspect(other)}"}

  @doc """
  Resolves imported guardrail names through a normalized guardrail registry.
  """
  @spec resolve_guardrail_names([name()], registry()) :: {:ok, [module()]} | {:error, String.t()}
  def resolve_guardrail_names(names, registry) when is_list(names) and is_map(registry) do
    names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case Map.fetch(registry, name) do
        {:ok, module} -> {:cont, {:ok, acc ++ [module]}}
        :error -> {:halt, {:error, "unknown guardrail #{inspect(name)}"}}
      end
    end)
  end

  def resolve_guardrail_names(_names, _registry),
    do: {:error, "guardrail names must be a list and registry must be a map"}

  defp ensure_compiled_guardrail(module) do
    cond do
      match?({:error, _}, Code.ensure_compiled(module)) ->
        {:error, "guardrail #{inspect(module)} could not be loaded"}

      missing = missing_functions(module) ->
        {:error, "guardrail #{inspect(module)} is not a valid Jidoka guardrail; missing #{Enum.join(missing, ", ")}"}

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
      {:error, "guardrail names must be unique within a Jidoka guardrail registry"}
    else
      :ok
    end
  end
end
