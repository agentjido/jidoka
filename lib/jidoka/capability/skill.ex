defmodule Jidoka.Skill do
  @moduledoc false

  alias Jido.AI.Skill
  alias Jidoka.Lifecycle.PhaseSpec

  @context_key :__jidoka_skills__
  @state_key :__jidoka_skill_runtime__

  @type ref :: module() | String.t()
  @type name :: String.t()
  @type registry :: %{required(name()) => module()}
  @type config :: %{
          refs: [ref()],
          load_paths: [String.t()]
        }

  @spec context_key() :: atom()
  def context_key, do: @context_key

  @spec enabled?(config() | nil) :: boolean()
  def enabled?(nil), do: false
  def enabled?(%{refs: refs}) when is_list(refs), do: refs != []
  def enabled?(_), do: false

  @spec requires_request_transformer?(config() | nil) :: boolean()
  def requires_request_transformer?(config), do: enabled?(config)

  @spec prompt_text(map()) :: String.t() | nil
  def prompt_text(runtime_context) when is_map(runtime_context) do
    runtime_context
    |> Map.get(@context_key, %{})
    |> Map.get(:prompt)
    |> case do
      prompt when is_binary(prompt) and prompt != "" -> prompt
      _ -> nil
    end
  end

  @spec normalize_dsl([struct()], String.t()) :: {:ok, config() | nil} | {:error, String.t()}
  def normalize_dsl([], _base_dir), do: {:ok, nil}

  def normalize_dsl(entries, base_dir) when is_list(entries) and is_binary(base_dir) do
    entries
    |> Enum.reduce_while({:ok, %{refs: [], load_paths: []}}, fn
      %Jidoka.Agent.Dsl.SkillRef{skill: skill}, {:ok, acc} ->
        with :ok <- validate_skill_ref(skill) do
          {:cont, {:ok, %{acc | refs: acc.refs ++ [skill]}}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      %Jidoka.Agent.Dsl.SkillPath{path: path}, {:ok, acc} ->
        with :ok <- validate_load_path(path) do
          expanded = Path.expand(path, base_dir)
          {:cont, {:ok, %{acc | load_paths: acc.load_paths ++ [expanded]}}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, %{refs: []}} ->
        {:ok, nil}

      {:ok, %{refs: refs, load_paths: load_paths}} ->
        {:ok, %{refs: refs, load_paths: Enum.uniq(load_paths)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec normalize_imported([ref()], [String.t()]) :: {:ok, config() | nil} | {:error, String.t()}
  def normalize_imported([], load_paths) when is_list(load_paths) do
    case normalize_load_paths(load_paths) do
      {:ok, _paths} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_imported(refs, load_paths) when is_list(refs) and is_list(load_paths) do
    with :ok <- validate_skill_refs(refs),
         {:ok, normalized_paths} <- normalize_load_paths(load_paths) do
      {:ok, %{refs: refs, load_paths: normalized_paths}}
    end
  end

  def normalize_imported(refs, load_paths),
    do: {:error, "skills must be a list and skill_paths must be a list, got: #{inspect({refs, load_paths})}"}

  @spec normalize_available_skills([module()] | %{required(name()) => module()}) ::
          {:ok, registry()} | {:error, String.t()}
  def normalize_available_skills(modules) when is_list(modules) do
    modules
    |> Enum.reduce_while({:ok, %{}}, fn module, {:ok, acc} ->
      with {:ok, name} <- skill_name(module),
           :ok <- ensure_unique_registry_name(name, acc) do
        {:cont, {:ok, Map.put(acc, name, module)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_available_skills(registry) when is_map(registry) do
    registry
    |> Enum.reduce_while({:ok, %{}}, fn {name, module}, {:ok, acc} ->
      with true <- is_binary(name) or {:error, "skill registry keys must be strings"},
           trimmed <- String.trim(name),
           true <- trimmed != "" or {:error, "skill registry keys must not be empty"},
           {:ok, published_name} <- skill_name(module),
           true <-
             trimmed == published_name or
               {:error,
                "skill registry key #{inspect(trimmed)} must match published skill name #{inspect(published_name)}"},
           :ok <- ensure_unique_registry_name(trimmed, acc) do
        {:cont, {:ok, Map.put(acc, trimmed, module)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_available_skills(other),
    do:
      {:error,
       "available_skills must be a list of Jido.AI skill modules or a map of name => module, got: #{inspect(other)}"}

  @spec resolve_skill_refs([name()], registry()) :: {:ok, [ref()]} | {:error, String.t()}
  def resolve_skill_refs(names, registry) when is_list(names) and is_map(registry) do
    names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      ref = Map.get(registry, name, name)
      {:cont, {:ok, acc ++ [ref]}}
    end)
  end

  def resolve_skill_refs(_names, _registry),
    do: {:error, "skill names must be a list and registry must be a map"}

  @spec skill_name(module()) :: {:ok, name()} | {:error, String.t()}
  def skill_name(module) when is_atom(module) do
    with :ok <- validate_skill_module(module),
         name when is_binary(name) <- Skill.manifest(module).name,
         trimmed <- String.trim(name),
         true <- trimmed != "" do
      {:ok, trimmed}
    else
      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, "skill #{inspect(module)} must publish a non-empty string name"}
    end
  end

  def skill_name(other),
    do: {:error, "skill entries must be modules, got: #{inspect(other)}"}

  @spec validate_skill_module(module()) :: :ok | {:error, String.t()}
  def validate_skill_module(module) when is_atom(module) do
    cond do
      match?({:error, _}, Code.ensure_compiled(module)) ->
        {:error, "skill #{inspect(module)} could not be loaded"}

      not function_exported?(module, :manifest, 0) ->
        {:error, "skill #{inspect(module)} is not a valid Jido.AI skill; missing manifest/0"}

      true ->
        case Skill.resolve(module) do
          {:ok, _spec} -> :ok
          {:error, reason} -> {:error, format_skill_error(module, reason)}
        end
    end
  end

  def validate_skill_module(other),
    do: {:error, "skill entries must be modules, got: #{inspect(other)}"}

  @spec validate_skill_ref(ref()) :: :ok | {:error, String.t()}
  def validate_skill_ref(module) when is_atom(module), do: validate_skill_module(module)

  def validate_skill_ref(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" ->
        {:error, "skill names must not be empty"}

      not Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, trimmed) ->
        {:error, "invalid skill name #{inspect(name)}; expected lowercase alphanumeric with hyphens"}

      true ->
        :ok
    end
  end

  def validate_skill_ref(other),
    do: {:error, "skill entries must be modules or skill-name strings, got: #{inspect(other)}"}

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

  @spec action_modules(config() | nil) :: [module()]
  def action_modules(nil), do: []

  def action_modules(%{refs: refs}) when is_list(refs) do
    refs
    |> Enum.flat_map(fn
      module when is_atom(module) -> Skill.actions(module)
      _name -> []
    end)
    |> Enum.uniq()
  end

  @spec skill_names(config() | nil) :: [String.t()]
  def skill_names(nil), do: []

  def skill_names(%{refs: refs}) when is_list(refs) do
    refs
    |> Enum.reduce([], fn
      module, acc when is_atom(module) ->
        [Skill.manifest(module).name | acc]

      name, acc when is_binary(name) ->
        [name | acc]
    end)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  @spec on_before_cmd(Jido.Agent.t(), term(), config() | nil) ::
          {:ok, Jido.Agent.t(), term()} | {:error, term()}
  def on_before_cmd(agent, action, nil), do: {:ok, agent, action}

  def on_before_cmd(agent, {:ai_react_start, %{tool_context: context} = params}, %{} = config)
      when is_map(context) do
    loaded_paths = agent.state |> Map.get(@state_key, %{}) |> Map.get(:loaded_paths, MapSet.new())

    with {:ok, loaded_paths} <- ensure_loaded(config, loaded_paths),
         {:ok, resolved_refs} <- resolve_runtime_refs(config.refs),
         runtime_skill_info <- build_runtime_skill_info(resolved_refs),
         params <- apply_allowed_tools(params, runtime_skill_info.allowed_tools),
         context <- Map.put(context, @context_key, runtime_skill_info),
         :ok <- Jidoka.Debug.record_runtime_meta(context, %{skills: runtime_skill_info.names}) do
      {:ok, put_loaded_state(agent, loaded_paths), {:ai_react_start, Map.put(params, :tool_context, context)}}
    end
  end

  def on_before_cmd(agent, {:ai_react_start, params}, %{} = config) when is_map(params) do
    on_before_cmd(agent, {:ai_react_start, Map.put(params, :tool_context, %{})}, config)
  end

  def on_before_cmd(agent, action, _config), do: {:ok, agent, action}

  @doc false
  @spec before_phase_specs(config() | nil) :: [PhaseSpec.t()]
  def before_phase_specs(config) do
    [
      PhaseSpec.before(:skills_before, :skills, fn agent, action ->
        on_before_cmd(agent, action, config)
      end)
    ]
  end

  defp validate_skill_refs(refs) do
    refs
    |> Enum.reduce_while(:ok, fn ref, :ok ->
      case validate_skill_ref(ref) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_load_paths(load_paths) do
    load_paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case validate_load_path(path) do
        :ok -> {:cont, {:ok, acc ++ [path]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.uniq(paths)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_loaded(%{load_paths: []}, loaded_paths), do: {:ok, loaded_paths}

  defp ensure_loaded(%{load_paths: load_paths}, loaded_paths) do
    unloaded_paths = Enum.reject(load_paths, &MapSet.member?(loaded_paths, &1))

    case unloaded_paths do
      [] ->
        {:ok, loaded_paths}

      _ ->
        case Jido.AI.Skill.Registry.load_from_paths(unloaded_paths) do
          {:ok, _count} -> {:ok, Enum.reduce(unloaded_paths, loaded_paths, &MapSet.put(&2, &1))}
          {:error, reason} -> {:error, {:skill_load_failed, reason}}
        end
    end
  end

  defp resolve_runtime_refs(refs) do
    refs
    |> Enum.reduce_while({:ok, []}, fn
      module, {:ok, acc} when is_atom(module) ->
        {:cont, {:ok, acc ++ [module]}}

      name, {:ok, acc} when is_binary(name) ->
        case Skill.resolve(name) do
          {:ok, _spec} -> {:cont, {:ok, acc ++ [name]}}
          {:error, _reason} -> {:halt, {:error, {:skill_not_found, name}}}
        end
    end)
  end

  defp build_runtime_skill_info(resolved_refs) do
    prompt_refs =
      Enum.map(resolved_refs, fn
        module when is_atom(module) -> Skill.manifest(module)
        other -> other
      end)

    prompt =
      prompt_refs
      |> Skill.Prompt.render()
      |> case do
        "" -> nil
        value -> value
      end

    %{
      refs: resolved_refs,
      names: resolved_names(prompt_refs),
      prompt: prompt,
      allowed_tools: Skill.Prompt.collect_allowed_tools(prompt_refs)
    }
  end

  defp resolved_names(refs) do
    refs
    |> Enum.map(fn
      %Jido.AI.Skill.Spec{name: name} -> name
      module when is_atom(module) -> Skill.manifest(module).name
      name when is_binary(name) -> name
    end)
  end

  defp apply_allowed_tools(params, []), do: params

  defp apply_allowed_tools(params, allowed_tools) do
    allowed_set = MapSet.new(allowed_tools)

    narrowed =
      case Map.get(params, :allowed_tools) do
        nil -> allowed_tools
        tools when is_list(tools) -> Enum.filter(tools, &MapSet.member?(allowed_set, &1))
      end

    Map.put(params, :allowed_tools, narrowed)
  end

  defp format_skill_error(module, %{message: message}) when is_binary(message) do
    "skill #{inspect(module)} is not a valid Jido.AI skill: #{message}"
  end

  defp format_skill_error(module, reason) do
    "skill #{inspect(module)} is not a valid Jido.AI skill: #{inspect(reason)}"
  end

  defp put_loaded_state(agent, loaded_paths) do
    state =
      agent.state
      |> Map.get(@state_key, %{})
      |> Map.put(:loaded_paths, loaded_paths)

    %{agent | state: Map.put(agent.state, @state_key, state)}
  end

  defp ensure_unique_registry_name(name, acc) do
    if Map.has_key?(acc, name) do
      {:error, "skill names must be unique within a Jidoka skill registry"}
    else
      :ok
    end
  end
end
