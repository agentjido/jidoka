defmodule Jidoka.Adapter.Jido.Skill.ResolvedSkill do
  @moduledoc false

  alias Jido.AI.Skill.Spec

  @enforce_keys [:source, :spec, :action_modules, :prompt, :metadata]
  defstruct [:source, :spec, action_modules: [], prompt: nil, metadata: %{}]

  @type t :: %__MODULE__{
          source: module() | String.t(),
          spec: Spec.t(),
          action_modules: [module()],
          prompt: String.t() | nil,
          metadata: map()
        }
end

defmodule Jidoka.Adapter.Jido.Skill.Resolution do
  @moduledoc false

  alias Jidoka.Adapter.Jido.Skill.ResolvedSkill

  @enforce_keys [:skills, :action_modules, :prompt, :metadata]
  defstruct skills: [], action_modules: [], prompt: nil, metadata: []

  @type t :: %__MODULE__{
          skills: [ResolvedSkill.t()],
          action_modules: [module()],
          prompt: String.t() | nil,
          metadata: [map()]
        }
end

defmodule Jidoka.Adapter.Jido.Skill do
  @moduledoc """
  Jido.AI skill helpers used by the Jidoka DSL.

  Skills are definition-time data in Jidoka. A skill contributes prompt
  instructions and any action modules published by the skill manifest. Those
  actions are still executed through the normal Jido action operation path.
  """

  alias Jido.AI.Skill
  alias Jido.AI.Skill.Spec
  alias Jido.AI.Skill.Registry
  alias __MODULE__.{Resolution, ResolvedSkill}

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

  @doc "Resolves ordered skill references into one stable snapshot."
  @spec resolve([ref()], keyword()) :: {:ok, Resolution.t()} | {:error, term()}
  def resolve(refs, opts \\ []) when is_list(refs) and is_list(opts) do
    with :ok <- load_paths(Keyword.get(opts, :load_paths, [])),
         {:ok, skills} <- resolve_skills(refs) do
      specs = Enum.map(skills, & &1.spec)
      prompt = render_prompt(specs)

      {:ok,
       %Resolution{
         skills: skills,
         action_modules: skills |> Enum.flat_map(& &1.action_modules) |> Enum.uniq(),
         prompt: prompt,
         metadata: Enum.map(skills, & &1.metadata)
       }}
    end
  end

  @doc "Returns action modules contributed by skill references or one resolution."
  @spec action_modules([ref()] | Resolution.t(), keyword()) :: [module()]
  def action_modules(refs_or_resolution, opts \\ [])

  def action_modules(%Resolution{action_modules: action_modules}, []), do: action_modules

  def action_modules(refs, opts) when is_list(refs) and is_list(opts) do
    case resolve(refs, opts) do
      {:ok, resolution} -> action_modules(resolution)
      {:error, _reason} -> []
    end
  end

  @doc "Renders prompt text from skill references or one resolution."
  @spec prompt([ref()] | Resolution.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def prompt(refs_or_resolution, opts \\ [])

  def prompt(%Resolution{prompt: prompt}, []), do: {:ok, prompt}

  def prompt(refs, opts) when is_list(refs) and is_list(opts) do
    with {:ok, resolution} <- resolve(refs, opts) do
      prompt(resolution)
    end
  end

  @doc "Returns serializable metadata from skill references or one resolution."
  @spec metadata([ref()] | Resolution.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def metadata(refs_or_resolution, opts \\ [])

  def metadata(%Resolution{metadata: metadata}, []), do: {:ok, metadata}

  def metadata(refs, opts) when is_list(refs) and is_list(opts) do
    with {:ok, resolution} <- resolve(refs, opts) do
      metadata(resolution)
    end
  end

  @doc false
  @spec name(ref()) :: String.t()
  def name(skill) do
    skill
    |> Skill.manifest()
    |> Map.fetch!(:name)
  end

  @doc "Expands skill load paths relative to a base directory."
  @spec normalize_load_paths([String.t()], String.t()) :: [String.t()]
  def normalize_load_paths(paths, base_dir) when is_list(paths) and is_binary(base_dir) do
    paths
    |> Enum.map(&Path.expand(&1, base_dir))
    |> Enum.uniq()
  end

  defp resolve_skills(refs) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
      case resolve_skill(ref) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, skills} -> {:ok, Enum.reverse(skills)}
      error -> error
    end)
  end

  defp resolve_skill(ref) do
    with {:ok, %Spec{} = spec} <- resolve_ref(ref),
         {:ok, action_modules} <- validate_actions(ref, spec.actions),
         {:ok, body} <- read_body(ref, spec) do
      spec = %Spec{spec | actions: action_modules, body_ref: {:inline, body}}

      {:ok,
       %ResolvedSkill{
         source: ref,
         spec: spec,
         action_modules: action_modules,
         prompt: render_prompt([spec]),
         metadata: skill_metadata(spec)
       }}
    end
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
         {:ok, spec} <- Skill.resolve(module) do
      {:ok, spec}
    else
      {:error, reason} -> {:error, {:invalid_skill, module, reason}}
    end
  end

  defp resolve_ref(name) when is_binary(name) do
    name = String.trim(name)

    with :ok <- validate_ref(name),
         {:ok, spec} <- Skill.resolve(name) do
      {:ok, spec}
    else
      {:error, reason} -> {:error, {:invalid_skill, name, reason}}
    end
  end

  defp validate_actions(ref, actions) when is_list(actions) do
    Enum.reduce_while(actions, {:ok, []}, fn action, {:ok, acc} ->
      case validate_action(action) do
        :ok -> {:cont, {:ok, [action | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_skill_action, ref, action, reason}}}
      end
    end)
    |> then(fn
      {:ok, action_modules} -> {:ok, action_modules |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end)
  end

  defp validate_actions(ref, actions),
    do: {:error, {:invalid_skill_actions, ref, actions}}

  defp validate_action(action) when is_atom(action) do
    with {:module, _module} <- Code.ensure_compiled(action),
         true <- function_exported?(action, :to_tool, 0) do
      :ok
    else
      {:error, reason} -> {:error, {:not_compiled, reason}}
      false -> {:error, :missing_to_tool}
    end
  end

  defp validate_action(_action), do: {:error, :not_a_module}

  defp read_body(ref, spec) do
    {:ok, Skill.body(spec)}
  rescue
    exception -> {:error, {:invalid_skill_body, ref, Exception.message(exception)}}
  end

  defp render_prompt(specs) do
    case Skill.Prompt.render(specs, include_body: true) do
      "" -> nil
      prompt -> prompt
    end
  end

  defp skill_metadata(spec) do
    %{
      "source" => "skill",
      "name" => spec.name,
      "description" => spec.description,
      "allowed_tools" => spec.allowed_tools,
      "actions" => Enum.map(spec.actions, &inspect/1)
    }
    |> reject_empty()
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
