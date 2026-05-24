defmodule Jidoka.Character do
  @moduledoc """
  Character rendering support for Jidoka agents.

  Characters are structured persona inputs rendered by `jido_character` into
  the effective system prompt. Jidoka keeps them separate from tools, memory,
  workflows, and handoffs: a character shapes voice and persona, while
  `agent.instructions` remains the explicit task and policy layer.
  """

  @context_key :__jidoka_character__

  @typedoc "A character source accepted by Jidoka."
  @type source :: :none | map() | module()

  @typedoc "Normalized character prompt source."
  @type spec :: nil | :none | {:character, Jido.Character.t()} | {:module, module()}

  @type registry :: %{required(String.t()) => source()}

  @doc """
  Internal runtime-context key used for per-request character overrides.
  """
  @spec context_key() :: atom()
  def context_key, do: @context_key

  @doc """
  Normalizes a compile-time or runtime character source.

  Maps are parsed through `Jido.Character.new/1`. Modules must be generated with
  `use Jido.Character`.
  """
  @spec normalize(module() | nil, term(), keyword()) :: {:ok, spec()} | {:error, String.t()}
  def normalize(owner_module, character, opts \\ [])

  def normalize(_owner_module, nil, _opts), do: {:ok, nil}
  def normalize(_owner_module, :none, _opts), do: {:ok, :none}

  def normalize(_owner_module, %_{} = character, opts), do: normalize_character_map(Map.from_struct(character), opts)
  def normalize(_owner_module, character, opts) when is_map(character), do: normalize_character_map(character, opts)

  def normalize(_owner_module, module, opts) when is_atom(module) do
    case Code.ensure_compiled(module) do
      {:module, ^module} ->
        if jido_character_module?(module) do
          {:ok, {:module, module}}
        else
          {:error, "#{label(opts)} module #{inspect(module)} must be a `use Jido.Character` module"}
        end

      {:error, reason} ->
        {:error, "#{label(opts)} module #{inspect(module)} could not be loaded: #{inspect(reason)}"}
    end
  end

  def normalize(_owner_module, other, opts) do
    {:error, "#{label(opts)} must be a map, `use Jido.Character` module, or :none, got: #{inspect(other)}"}
  end

  @doc """
  Resolves a normalized character source into prompt text.
  """
  @spec resolve(spec(), map()) :: {:ok, String.t() | nil} | {:error, term()}
  def resolve(character, input)

  def resolve(nil, _input), do: {:ok, nil}
  def resolve(:none, _input), do: {:ok, nil}
  def resolve({:character, character}, _input), do: render_character(character)
  def resolve({:module, module}, _input), do: render_module(module)
  def resolve(character, _input) when is_map(character), do: normalize(nil, character) |> resolve_normalized()
  def resolve(character, _input) when is_atom(character), do: normalize(nil, character) |> resolve_normalized()

  @doc """
  Resolves a request-level character override from runtime context.
  """
  @spec runtime_override(map()) :: spec() | nil
  def runtime_override(context) when is_map(context), do: Map.get(context, @context_key)
  def runtime_override(_context), do: nil

  @doc false
  @spec normalize_available_characters(registry() | keyword()) :: {:ok, registry()} | {:error, String.t()}
  def normalize_available_characters(characters) when is_list(characters) do
    characters
    |> Enum.into(%{})
    |> normalize_available_characters()
  rescue
    _ -> {:error, "available_characters must be a map of character name => character source"}
  end

  def normalize_available_characters(characters) when is_map(characters) do
    characters
    |> Enum.reduce_while({:ok, %{}}, fn {name, source}, {:ok, acc} ->
      with {:ok, name} <- normalize_registry_name(name),
           :ok <- ensure_unique_registry_name(name, acc),
           {:ok, _spec} <- normalize(nil, source, label: "available character #{inspect(name)}") do
        {:cont, {:ok, Map.put(acc, name, source)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_available_characters(_characters),
    do: {:error, "available_characters must be a map of character name => character source"}

  @doc false
  @spec resolve_character_name(String.t(), registry()) :: {:ok, source()} | {:error, String.t()}
  def resolve_character_name(name, registry) when is_binary(name) and is_map(registry) do
    case Map.fetch(registry, name) do
      {:ok, source} -> {:ok, source}
      :error -> {:error, "unknown character #{inspect(name)}"}
    end
  end

  def resolve_character_name(_name, _registry),
    do: {:error, "character name must be a string and registry must be a map"}

  defp normalize_character_map(character, opts) do
    case Jido.Character.new(character) do
      {:ok, character} -> {:ok, {:character, character}}
      {:error, errors} -> {:error, "#{label(opts)} is invalid: #{format_errors(errors)}"}
    end
  end

  defp resolve_normalized({:ok, normalized}), do: resolve(normalized, %{})
  defp resolve_normalized({:error, reason}), do: {:error, reason}

  defp render_module(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         {:ok, character} <- new_module_character(module) do
      render_module_character(module, character)
    else
      {:error, reason} -> {:error, "character module #{inspect(module)} could not be rendered: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "character module #{inspect(module)} failed: #{Exception.message(error)}"}
  end

  defp new_module_character(module) do
    case apply(module, :new, []) do
      {:ok, character} -> {:ok, character}
      {:error, reason} -> {:error, reason}
      other -> {:error, "new/0 returned #{inspect(other)}"}
    end
  end

  defp render_module_character(module, character) do
    cond do
      function_exported?(module, :to_system_prompt, 1) ->
        normalize_prompt(apply(module, :to_system_prompt, [character]))

      function_exported?(module, :to_system_prompt, 2) ->
        normalize_prompt(apply(module, :to_system_prompt, [character, []]))

      true ->
        {:error, "missing to_system_prompt/1 or to_system_prompt/2"}
    end
  end

  defp render_character(character), do: normalize_prompt(Jido.Character.to_system_prompt(character))

  defp normalize_prompt(prompt) when is_binary(prompt) do
    case String.trim(prompt) do
      "" -> {:error, "character rendered an empty prompt"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_prompt(other), do: {:error, "character rendered #{inspect(other)}"}

  defp jido_character_module?(module) do
    function_exported?(module, :definition, 0) and
      match?(%Jido.Character.Definition{module: ^module}, apply(module, :definition, []))
  rescue
    _ -> false
  end

  defp format_errors(errors) when is_list(errors) do
    errors
    |> Enum.map(fn
      %{path: path, message: message} when is_list(path) and path != [] ->
        "#{Enum.join(path, ".")}: #{message}"

      %{message: message} ->
        message

      other ->
        inspect(other)
    end)
    |> Enum.join(", ")
  end

  defp normalize_registry_name(name) when is_atom(name), do: normalize_registry_name(Atom.to_string(name))

  defp normalize_registry_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, "character registry keys must not be empty"}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_registry_name(_name), do: {:error, "character registry keys must be strings or atoms"}

  defp ensure_unique_registry_name(name, registry) do
    if Map.has_key?(registry, name) do
      {:error, "duplicate character #{inspect(name)} in available_characters"}
    else
      :ok
    end
  end

  defp label(opts), do: Keyword.get(opts, :label, "character")
end
