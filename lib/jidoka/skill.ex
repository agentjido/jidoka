defmodule Jidoka.Skill do
  @moduledoc """
  Jido.AI skill helpers used by the Jidoka DSL.

  Skills are definition-time data in Jidoka V2. A skill contributes prompt
  instructions and any action modules published by the skill manifest. Those
  actions are still executed through the normal Jido action operation path.
  """

  alias Jido.AI.Skill
  alias Jido.AI.Skill.Registry

  @type ref :: module() | String.t()

  @doc "Validates a skill reference from the DSL or imported agent spec."
  @spec validate_ref(ref()) :: :ok | {:error, String.t()}
  def validate_ref(module) when is_atom(module), do: validate_module(module)

  def validate_ref(name) when is_binary(name) do
    name = String.trim(name)

    cond do
      name == "" ->
        {:error, "skill names must not be empty"}

      not Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, name) ->
        {:error, "invalid skill name #{inspect(name)}; expected lowercase words separated by hyphens"}

      true ->
        :ok
    end
  end

  def validate_ref(other),
    do: {:error, "skill entries must be modules or skill-name strings, got: #{inspect(other)}"}

  @doc "Validates a skill load path before it is expanded relative to an agent source file."
  @spec validate_load_path(term()) :: :ok | {:error, String.t()}
  def validate_load_path(path) when is_binary(path) do
    if String.trim(path) == "" do
      {:error, "skill load paths must not be empty"}
    else
      :ok
    end
  end

  def validate_load_path(other),
    do: {:error, "skill load paths must be strings, got: #{inspect(other)}"}

  @doc "Returns action modules contributed by a list of skill references."
  @spec action_modules([ref()], keyword()) :: [module()]
  def action_modules(refs, opts \\ []) when is_list(refs) and is_list(opts) do
    refs
    |> maybe_load_paths(opts)
    |> Enum.flat_map(fn
      module when is_atom(module) ->
        Skill.actions(module)

      name when is_binary(name) ->
        case Skill.resolve(name) do
          {:ok, spec} -> Skill.actions(spec)
          {:error, _reason} -> []
        end
    end)
    |> Enum.uniq()
  end

  @doc "Renders prompt text contributed by a list of skill references."
  @spec prompt([ref()], keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def prompt(refs, opts \\ []) when is_list(refs) and is_list(opts) do
    with {:ok, refs} <- load_and_resolve(refs, opts) do
      refs
      |> Skill.Prompt.render()
      |> case do
        "" -> {:ok, nil}
        prompt -> {:ok, prompt}
      end
    end
  end

  @doc "Returns serializable metadata for resolved skill references."
  @spec metadata([ref()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def metadata(refs, opts \\ []) when is_list(refs) and is_list(opts) do
    with {:ok, refs} <- load_and_resolve(refs, opts) do
      {:ok,
       Enum.map(refs, fn ref ->
         spec = Skill.manifest(ref)

         %{
           "source" => "skill",
           "name" => spec.name,
           "description" => spec.description,
           "allowed_tools" => spec.allowed_tools,
           "actions" => Enum.map(spec.actions, &inspect/1)
         }
         |> reject_empty()
       end)}
    end
  end

  @doc "Expands skill load paths relative to a base directory."
  @spec normalize_load_paths([String.t()], String.t()) :: [String.t()]
  def normalize_load_paths(paths, base_dir) when is_list(paths) and is_binary(base_dir) do
    paths
    |> Enum.map(&Path.expand(&1, base_dir))
    |> Enum.uniq()
  end

  defp load_and_resolve(refs, opts) do
    load_paths = Keyword.get(opts, :load_paths, [])

    with :ok <- load_paths(load_paths) do
      resolve_refs(refs)
    end
  end

  defp resolve_refs(refs) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
      case resolve_ref(ref) do
        {:ok, resolved} -> {:cont, {:ok, acc ++ [resolved]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_load_paths(refs, opts) do
    _ = load_paths(Keyword.get(opts, :load_paths, []))
    refs
  end

  defp load_paths([]), do: :ok

  defp load_paths(paths) when is_list(paths) do
    case Registry.load_from_paths(paths) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, {:skill_load_failed, reason}}
    end
  end

  defp resolve_ref(module) when is_atom(module) do
    with :ok <- validate_module(module),
         {:ok, _spec} <- Skill.resolve(module) do
      {:ok, module}
    else
      {:error, reason} -> {:error, {:invalid_skill, module, reason}}
    end
  end

  defp resolve_ref(name) when is_binary(name) do
    name = String.trim(name)

    with :ok <- validate_ref(name),
         {:ok, _spec} <- Skill.resolve(name) do
      {:ok, name}
    else
      {:error, reason} -> {:error, {:invalid_skill, name, reason}}
    end
  end

  defp validate_module(module) when is_atom(module) do
    with {:module, _module} <- Code.ensure_compiled(module),
         true <- function_exported?(module, :manifest, 0),
         true <- function_exported?(module, :body, 0),
         true <- function_exported?(module, :actions, 0) do
      :ok
    else
      {:error, reason} ->
        {:error, "skill #{inspect(module)} could not be loaded: #{inspect(reason)}"}

      false ->
        {:error, "skill #{inspect(module)} must expose manifest/0, body/0, and actions/0"}
    end
  end

  defp reject_empty(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, []} -> true
      {_key, ""} -> true
      {_key, _value} -> false
    end)
  end
end
