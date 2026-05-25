defmodule Jidoka.Subagent do
  @moduledoc """
  Registry and runtime helpers for Jidoka manager-pattern subagents.

  Subagents are exposed to a parent agent as tool-like specialists. The parent
  remains in control of the turn, delegates a single bounded task to the child,
  and receives a result back. A subagent call does not change the conversation
  owner; use a handoff when future turns should route to another agent.
  """

  alias Jidoka.Subagent.{Definition, Runtime, Tool}

  @enforce_keys [:agent, :name, :description, :target, :timeout, :forward_context, :result]
  defstruct [:agent, :name, :description, :target, :timeout, :forward_context, :result]

  @type name :: String.t()
  @type target :: :ephemeral | {:peer, String.t()} | {:peer, {:context, atom() | String.t()}}
  @type forward_context ::
          :public | :none | {:only, [atom() | String.t()]} | {:except, [atom() | String.t()]}
  @type result_mode :: :text | :structured
  @type registry :: %{required(name()) => module()}
  @type t :: %__MODULE__{
          agent: module(),
          name: name(),
          description: String.t(),
          target: target(),
          timeout: pos_integer(),
          forward_context: forward_context(),
          result: result_mode()
        }

  @doc """
  Returns the fixed input schema used by generated subagent tools.
  """
  @spec task_schema() :: Zoi.schema()
  defdelegate task_schema, to: Tool

  @doc """
  Returns the generated tool output schema for a subagent definition.
  """
  @spec output_schema(t()) :: Zoi.schema()
  defdelegate output_schema(subagent), to: Tool

  @doc """
  Returns the internal context key used to associate calls with a parent request.
  """
  @spec request_id_key() :: atom()
  defdelegate request_id_key, to: Jidoka.Subagent.Context

  @doc false
  @spec server_key() :: atom()
  defdelegate server_key, to: Jidoka.Subagent.Context

  @doc false
  @spec depth_key() :: atom()
  defdelegate depth_key, to: Jidoka.Subagent.Context

  @doc false
  @spec validate_agent_module(module()) :: :ok | {:error, String.t()}
  defdelegate validate_agent_module(module), to: Definition

  @doc false
  @spec agent_name(module()) :: {:ok, name()} | {:error, String.t()}
  defdelegate agent_name(module), to: Definition

  @doc false
  @spec subagent_names([t()]) :: {:ok, [name()]} | {:error, String.t()}
  defdelegate subagent_names(subagents), to: Definition

  @doc false
  @spec new(module(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(agent_module, opts \\ []) do
    with {:ok, subagent} <- Definition.new(agent_module, opts) do
      {:ok, wrap_subagent(subagent)}
    end
  end

  @doc false
  @spec normalize_available_subagents([module()] | %{required(name()) => module()}) ::
          {:ok, registry()} | {:error, String.t()}
  defdelegate normalize_available_subagents(subagents), to: Definition

  @doc false
  @spec resolve_subagent_name(name(), registry()) :: {:ok, module()} | {:error, String.t()}
  defdelegate resolve_subagent_name(name, registry), to: Definition

  @doc false
  @spec normalize_target(term()) :: {:ok, target()} | {:error, String.t()}
  defdelegate normalize_target(target), to: Definition

  @doc false
  @spec normalize_timeout(term()) :: {:ok, pos_integer()} | {:error, String.t()}
  defdelegate normalize_timeout(timeout), to: Definition

  @doc false
  @spec normalize_forward_context(term()) :: {:ok, forward_context()} | {:error, String.t()}
  defdelegate normalize_forward_context(forward_context), to: Definition

  @doc false
  @spec normalize_result(term()) :: {:ok, result_mode()} | {:error, String.t()}
  defdelegate normalize_result(result), to: Definition

  @doc false
  @spec tool_module(base_module :: module(), t(), non_neg_integer()) :: module()
  defdelegate tool_module(base_module, subagent, index), to: Tool

  @doc false
  @spec tool_module_ast(module(), t()) :: Macro.t()
  defdelegate tool_module_ast(tool_module, subagent), to: Tool

  @doc false
  @spec on_before_cmd(Jido.Agent.t(), term()) :: {:ok, Jido.Agent.t(), term()}
  defdelegate on_before_cmd(agent, action), to: Runtime

  @doc false
  @spec on_after_cmd(Jido.Agent.t(), term(), [term()]) :: {:ok, Jido.Agent.t(), [term()]}
  defdelegate on_after_cmd(agent, action, directives), to: Runtime

  @doc false
  @spec run_subagent_tool(t(), map(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate run_subagent_tool(subagent, params, context), to: Runtime

  @doc false
  @spec run_subagent(t(), map(), map()) :: {:ok, String.t()} | {:error, term()}
  defdelegate run_subagent(subagent, params, context), to: Runtime

  @doc false
  @spec get_request_meta(Jido.Agent.t(), String.t()) :: map() | nil
  defdelegate get_request_meta(agent, request_id), to: Runtime

  @doc """
  Returns the recorded subagent calls for a request.

  This prefers persisted request metadata when available, and falls back to the
  transient ETS buffer used during live ReAct runs.
  """
  @spec request_calls(pid() | String.t() | Jido.Agent.t(), String.t()) :: [map()]
  defdelegate request_calls(server_or_agent, request_id), to: Runtime

  @doc """
  Returns the recorded subagent calls for the latest request on a running agent.
  """
  @spec latest_request_calls(pid() | String.t()) :: [map()]
  defdelegate latest_request_calls(server_or_id), to: Runtime

  defp wrap_subagent(%{} = attrs) do
    fields = [:agent, :name, :description, :target, :timeout, :forward_context, :result]
    struct(__MODULE__, Map.take(attrs, fields))
  end
end
