defmodule Jidoka.Workflow.Capability do
  @moduledoc false

  alias Jidoka.Lifecycle.PhaseSpec
  alias Jidoka.Workflow.Capability.{Runtime, Tool}

  @enforce_keys [:workflow, :name, :description, :timeout, :forward_context, :result]
  defstruct [:workflow, :name, :description, :timeout, :forward_context, :result]

  @type name :: String.t()
  @type forward_context :: Jidoka.Subagent.forward_context()
  @type result_mode :: :output | :structured
  @type registry :: %{required(name()) => module()}
  @type t :: %__MODULE__{
          workflow: module(),
          name: name(),
          description: String.t(),
          timeout: pos_integer(),
          forward_context: forward_context(),
          result: result_mode()
        }

  @doc false
  @spec new(module(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(workflow_module, opts \\ [])

  def new(workflow_module, opts) when is_list(opts) do
    with {:ok, definition} <- workflow_definition(workflow_module),
         {:ok, name} <- normalize_name(Keyword.get(opts, :as), definition.id),
         {:ok, description} <- normalize_description(Keyword.get(opts, :description), definition),
         {:ok, timeout} <- normalize_timeout(Keyword.get(opts, :timeout, 30_000)),
         {:ok, forward_context} <- normalize_forward_context(Keyword.get(opts, :forward_context, :public)),
         {:ok, result} <- normalize_result(Keyword.get(opts, :result, :output)) do
      {:ok,
       %__MODULE__{
         workflow: workflow_module,
         name: name,
         description: description,
         timeout: timeout,
         forward_context: forward_context,
         result: result
       }}
    end
  end

  def new(_workflow_module, _opts), do: {:error, "workflow operation options must be a keyword list"}

  @doc false
  @spec workflow_name(module()) :: {:ok, name()} | {:error, String.t()}
  def workflow_name(workflow_module) do
    with {:ok, definition} <- workflow_definition(workflow_module) do
      {:ok, definition.id}
    end
  end

  @doc false
  @spec workflow_names([t()]) :: {:ok, [name()]} | {:error, String.t()}
  def workflow_names(workflows) when is_list(workflows) do
    names = Enum.map(workflows, & &1.name)

    if Enum.uniq(names) == names do
      {:ok, names}
    else
      {:error, "workflow operation names must be unique within a Jidoka agent"}
    end
  end

  @doc false
  @spec normalize_available_workflows([module()] | %{required(name()) => module()}) ::
          {:ok, registry()} | {:error, String.t()}
  def normalize_available_workflows(modules) when is_list(modules) do
    modules
    |> Enum.reduce_while({:ok, %{}}, fn module, {:ok, acc} ->
      with {:ok, name} <- workflow_name(module),
           :ok <- ensure_unique_registry_name(name, acc) do
        {:cont, {:ok, Map.put(acc, name, module)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_available_workflows(registry) when is_map(registry) do
    registry
    |> Enum.reduce_while({:ok, %{}}, fn {name, module}, {:ok, acc} ->
      with true <- is_binary(name) or {:error, "workflow registry keys must be strings"},
           trimmed <- String.trim(name),
           true <- trimmed != "" or {:error, "workflow registry keys must not be empty"},
           {:ok, published_name} <- workflow_name(module),
           true <-
             trimmed == published_name or
               {:error,
                "workflow registry key #{inspect(trimmed)} must match published workflow id #{inspect(published_name)}"},
           :ok <- ensure_unique_registry_name(trimmed, acc) do
        {:cont, {:ok, Map.put(acc, trimmed, module)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_available_workflows(other),
    do:
      {:error,
       "available_workflows must be a list of Jidoka workflow modules or a map of workflow id => module, got: #{inspect(other)}"}

  @doc false
  @spec resolve_workflow_name(name(), registry()) :: {:ok, module()} | {:error, String.t()}
  def resolve_workflow_name(name, registry) when is_binary(name) and is_map(registry) do
    case Map.fetch(registry, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, "unknown workflow #{inspect(name)}"}
    end
  end

  def resolve_workflow_name(_name, _registry),
    do: {:error, "workflow name must be a string and registry must be a map"}

  @doc false
  @spec input_schema(t()) :: Zoi.schema()
  defdelegate input_schema(workflow), to: Tool

  @doc false
  @spec output_schema(t()) :: Zoi.schema()
  defdelegate output_schema(workflow), to: Tool

  @doc false
  @spec tool_module(base_module :: module(), t(), non_neg_integer()) :: module()
  defdelegate tool_module(base_module, workflow, index), to: Tool

  @doc false
  @spec tool_module_ast(module(), t()) :: Macro.t()
  defdelegate tool_module_ast(tool_module, workflow), to: Tool

  @doc false
  @spec run_workflow_tool(t(), map(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate run_workflow_tool(workflow, params, context), to: Runtime

  @doc false
  @spec on_after_cmd(Jido.Agent.t(), term(), [term()]) :: {:ok, Jido.Agent.t(), [term()]}
  defdelegate on_after_cmd(agent, action, directives), to: Runtime

  @doc false
  @spec after_phase_specs() :: [PhaseSpec.t()]
  def after_phase_specs do
    [
      PhaseSpec.after_phase(:workflow_after, :workflow, &on_after_cmd/3)
    ]
  end

  @doc false
  @spec get_request_meta(Jido.Agent.t(), String.t()) :: map() | nil
  defdelegate get_request_meta(agent, request_id), to: Runtime

  @doc false
  @spec request_calls(pid() | String.t() | Jido.Agent.t(), String.t()) :: [map()]
  defdelegate request_calls(server_or_agent, request_id), to: Runtime

  @doc false
  @spec latest_request_calls(pid() | String.t()) :: [map()]
  defdelegate latest_request_calls(server_or_id), to: Runtime

  defp workflow_definition(workflow_module) when is_atom(workflow_module) do
    case Jidoka.Workflow.definition(workflow_module) do
      {:ok, definition} ->
        {:ok, definition}

      {:error, reason} ->
        {:error, "workflow #{inspect(workflow_module)} is not a valid Jidoka workflow: #{Jidoka.Error.format(reason)}"}
    end
  end

  defp workflow_definition(other), do: {:error, "workflow entries must be modules, got: #{inspect(other)}"}

  defp normalize_name(nil, default_name), do: normalize_name(default_name, default_name)
  defp normalize_name(name, _default_name) when is_atom(name), do: normalize_name(Atom.to_string(name), nil)

  defp normalize_name(name, _default_name) when is_binary(name) do
    trimmed = String.trim(name)

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, trimmed) do
      {:ok, trimmed}
    else
      {:error,
       "workflow operation names must start with a lowercase letter and contain only lowercase letters, numbers, and underscores"}
    end
  end

  defp normalize_name(other, _default_name),
    do: {:error, "workflow operation name must be an atom or string, got: #{inspect(other)}"}

  defp normalize_description(nil, %{id: id, description: description}) do
    description =
      description
      |> case do
        text when is_binary(text) and text != "" -> text
        _ -> "Run #{id} workflow."
      end

    {:ok, description}
  end

  defp normalize_description(description, _definition) when is_binary(description) do
    case String.trim(description) do
      "" -> {:error, "workflow operation descriptions must not be empty"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_description(other, _definition),
    do: {:error, "workflow operation descriptions must be strings, got: #{inspect(other)}"}

  defp normalize_result(result) when result in [:output, "output"], do: {:ok, :output}
  defp normalize_result(result) when result in [:structured, "structured"], do: {:ok, :structured}

  defp normalize_result(other),
    do: {:error, "workflow operation result must be :output or :structured, got: #{inspect(other)}"}

  defp normalize_timeout(timeout) do
    case Jidoka.Subagent.normalize_timeout(timeout) do
      {:ok, timeout} -> {:ok, timeout}
      {:error, message} -> {:error, String.replace(message, "subagent timeout", "workflow operation timeout")}
    end
  end

  defp normalize_forward_context(forward_context) do
    case Jidoka.Subagent.normalize_forward_context(forward_context) do
      {:ok, forward_context} ->
        {:ok, forward_context}

      {:error, message} ->
        {:error, String.replace(message, "subagent forward_context", "workflow operation forward_context")}
    end
  end

  defp ensure_unique_registry_name(name, acc) do
    if Map.has_key?(acc, name) do
      {:error, "duplicate workflow #{inspect(name)} in available_workflows"}
    else
      :ok
    end
  end
end
