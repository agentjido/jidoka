defmodule Jidoka.Handoff.Capability do
  @moduledoc false

  alias Jidoka.Handoff.{Runtime, Tool}

  @enforce_keys [:agent, :name, :description, :target, :forward_context]
  defstruct [:agent, :name, :description, :target, :forward_context]

  @type name :: String.t()
  @type target :: :auto | {:peer, String.t()} | {:peer, {:context, atom() | String.t()}}
  @type registry :: %{required(name()) => module()}
  @type t :: %__MODULE__{
          agent: module(),
          name: name(),
          description: String.t(),
          target: target(),
          forward_context: Jidoka.Subagent.forward_context()
        }

  @doc false
  @spec new(module(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(agent_module, opts \\ [])

  def new(agent_module, opts) when is_atom(agent_module) and is_list(opts) do
    with :ok <- Jidoka.Subagent.validate_agent_module(agent_module),
         {:ok, default_name} <- agent_name(agent_module),
         {:ok, name} <- normalize_name(Keyword.get(opts, :as), default_name),
         {:ok, description} <- normalize_description(Keyword.get(opts, :description), agent_module, name),
         {:ok, target} <- normalize_target(Keyword.get(opts, :target, :auto)),
         {:ok, forward_context} <-
           Jidoka.Subagent.normalize_forward_context(Keyword.get(opts, :forward_context, :public)) do
      {:ok,
       %__MODULE__{
         agent: agent_module,
         name: name,
         description: description,
         target: target,
         forward_context: forward_context
       }}
    end
  end

  def new(_agent_module, _opts), do: {:error, "handoff entries must be Jidoka agent modules"}

  @doc false
  @spec agent_name(module()) :: {:ok, name()} | {:error, String.t()}
  def agent_name(module), do: Jidoka.Subagent.agent_name(module)

  @doc false
  @spec handoff_names([t()]) :: {:ok, [name()]} | {:error, String.t()}
  def handoff_names(handoffs) when is_list(handoffs) do
    names = Enum.map(handoffs, & &1.name)

    if Enum.uniq(names) == names do
      {:ok, names}
    else
      {:error, "handoff names must be unique within a Jidoka agent"}
    end
  end

  @doc false
  @spec normalize_available_handoffs([module()] | %{required(name()) => module()}) ::
          {:ok, registry()} | {:error, String.t()}
  def normalize_available_handoffs(modules) when is_list(modules) do
    modules
    |> Enum.reduce_while({:ok, %{}}, fn module, {:ok, acc} ->
      with {:ok, name} <- agent_name(module),
           :ok <- ensure_unique_registry_name(name, acc) do
        {:cont, {:ok, Map.put(acc, name, module)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_available_handoffs(registry) when is_map(registry) do
    registry
    |> Enum.reduce_while({:ok, %{}}, fn {name, module}, {:ok, acc} ->
      with true <- is_binary(name) or {:error, "handoff registry keys must be strings"},
           trimmed <- String.trim(name),
           true <- trimmed != "" or {:error, "handoff registry keys must not be empty"},
           {:ok, published_name} <- agent_name(module),
           true <-
             trimmed == published_name or
               {:error,
                "handoff registry key #{inspect(trimmed)} must match published agent name #{inspect(published_name)}"},
           :ok <- ensure_unique_registry_name(trimmed, acc) do
        {:cont, {:ok, Map.put(acc, trimmed, module)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_available_handoffs(other),
    do:
      {:error,
       "available_handoffs must be a list of Jidoka agent modules or a map of handoff name => module, got: #{inspect(other)}"}

  @doc false
  @spec resolve_handoff_name(name(), registry()) :: {:ok, module()} | {:error, String.t()}
  def resolve_handoff_name(name, registry) when is_binary(name) and is_map(registry) do
    case Map.fetch(registry, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, "unknown handoff #{inspect(name)}"}
    end
  end

  def resolve_handoff_name(_name, _registry),
    do: {:error, "handoff name must be a string and registry must be a map"}

  @doc false
  @spec input_schema() :: Zoi.schema()
  defdelegate input_schema, to: Tool

  @doc false
  @spec output_schema() :: Zoi.schema()
  defdelegate output_schema, to: Tool

  @doc false
  @spec tool_module(module(), t(), non_neg_integer()) :: module()
  defdelegate tool_module(base_module, handoff, index), to: Tool

  @doc false
  @spec tool_module_ast(module(), t()) :: Macro.t()
  defdelegate tool_module_ast(tool_module, handoff), to: Tool

  @doc false
  @spec run_handoff_tool(t(), map(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate run_handoff_tool(handoff, params, context), to: Runtime

  @doc false
  @spec on_before_cmd(Jido.Agent.t(), term()) :: {:ok, Jido.Agent.t(), term()}
  defdelegate on_before_cmd(agent, action), to: Runtime

  @doc false
  @spec on_after_cmd(Jido.Agent.t(), term(), [term()]) :: {:ok, Jido.Agent.t(), [term()]}
  defdelegate on_after_cmd(agent, action, directives), to: Runtime

  @doc false
  @spec get_request_meta(Jido.Agent.t(), String.t()) :: map() | nil
  defdelegate get_request_meta(agent, request_id), to: Runtime

  @doc false
  @spec request_calls(pid() | String.t() | Jido.Agent.t(), String.t()) :: [map()]
  defdelegate request_calls(server_or_agent, request_id), to: Runtime

  @doc false
  @spec latest_request_calls(pid() | String.t()) :: [map()]
  defdelegate latest_request_calls(server_or_id), to: Runtime

  defp normalize_name(nil, default_name), do: normalize_name(default_name, default_name)
  defp normalize_name(name, _default_name) when is_atom(name), do: normalize_name(Atom.to_string(name), nil)

  defp normalize_name(name, _default_name) when is_binary(name) do
    trimmed = String.trim(name)

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, trimmed) do
      {:ok, trimmed}
    else
      {:error,
       "handoff names must start with a lowercase letter and contain only lowercase letters, numbers, and underscores"}
    end
  end

  defp normalize_name(other, _default_name),
    do: {:error, "handoff name must be an atom or string, got: #{inspect(other)}"}

  defp normalize_description(nil, agent_module, name) do
    description =
      if function_exported?(agent_module, :__jidoka__, 0) do
        agent_module.__jidoka__()[:description]
      end

    {:ok, description || "Transfer conversation ownership to #{name}."}
  end

  defp normalize_description(description, _agent_module, _name) when is_binary(description) do
    case String.trim(description) do
      "" -> {:error, "handoff descriptions must not be empty"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_description(other, _agent_module, _name),
    do: {:error, "handoff descriptions must be strings, got: #{inspect(other)}"}

  defp normalize_target(:auto), do: {:ok, :auto}
  defp normalize_target("auto"), do: {:ok, :auto}

  defp normalize_target({:peer, peer_id}) when is_binary(peer_id),
    do: Jidoka.Subagent.normalize_target({:peer, peer_id})

  defp normalize_target({:peer, {:context, key}}) when is_atom(key) or is_binary(key),
    do: Jidoka.Subagent.normalize_target({:peer, {:context, key}})

  defp normalize_target(other),
    do: {:error, "handoff target must be :auto, {:peer, \"id\"}, or {:peer, {:context, key}}, got: #{inspect(other)}"}

  defp ensure_unique_registry_name(name, registry) do
    if Map.has_key?(registry, name) do
      {:error, "duplicate handoff #{inspect(name)} in available_handoffs"}
    else
      :ok
    end
  end
end
