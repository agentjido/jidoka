defmodule Jidoka.Workflow do
  @moduledoc """
  Minimal deterministic workflow contract for Jidoka.

  A workflow is application-owned deterministic code exposed to an agent as one
  model-callable operation. It is separate from the Runic agent turn spine: the
  agent chooses when to call it, while the workflow module owns the ordered
  process inside `run/2`.
  """

  alias Jidoka.Schema

  @callback run(input :: map(), context :: map()) :: {:ok, term()} | {:error, term()} | term()
  @callback id() :: String.t()
  @callback description() :: String.t() | nil
  @callback parameters_schema() :: map() | nil

  @optional_callbacks description: 0, parameters_schema: 0

  @type definition :: %{
          required(:id) => String.t(),
          required(:module) => module(),
          optional(:description) => String.t() | nil,
          optional(:parameters_schema) => map() | nil
        }

  @doc "Defines a deterministic workflow module for agent tool exposure."
  defmacro __using__(opts \\ []) do
    quote location: :keep do
      @behaviour Jidoka.Workflow
      @jidoka_workflow_opts unquote(opts)
      @before_compile Jidoka.Workflow
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    quote location: :keep do
      @impl Jidoka.Workflow
      def id do
        Jidoka.Workflow.normalize_id!(
          Keyword.get(@jidoka_workflow_opts, :id) || Keyword.get(@jidoka_workflow_opts, :name) ||
            __MODULE__
        )
      end

      @impl Jidoka.Workflow
      def description do
        Keyword.get(@jidoka_workflow_opts, :description)
      end

      @impl Jidoka.Workflow
      def parameters_schema do
        Keyword.get(@jidoka_workflow_opts, :parameters_schema) ||
          Keyword.get(@jidoka_workflow_opts, :input_schema)
      end

      def __jidoka_workflow__ do
        Jidoka.Workflow.definition!(__MODULE__)
      end

      defoverridable id: 0, description: 0, parameters_schema: 0
    end
  end

  @doc "Returns the normalized operation definition for a workflow module."
  @spec definition(module()) :: {:ok, definition()} | {:error, term()}
  def definition(workflow_module) when is_atom(workflow_module) do
    with {:module, _module} <- Code.ensure_compiled(workflow_module),
         true <- function_exported?(workflow_module, :run, 2),
         {:ok, id} <- normalize_id(workflow_id(workflow_module)),
         {:ok, description} <- normalize_description(workflow_description(workflow_module)),
         {:ok, parameters_schema} <-
           normalize_parameters_schema(parameters_schema(workflow_module)) do
      {:ok,
       %{
         id: id,
         module: workflow_module,
         description: description,
         parameters_schema: parameters_schema
       }}
    else
      {:error, reason} -> {:error, {:invalid_workflow_module, workflow_module, reason}}
      false -> {:error, {:invalid_workflow_module, workflow_module, :missing_run}}
    end
  end

  def definition(workflow_module), do: {:error, {:invalid_workflow_module, workflow_module}}

  @doc "Returns a workflow definition or raises when the workflow module is invalid."
  @spec definition!(module()) :: definition()
  def definition!(workflow_module) do
    case definition(workflow_module) do
      {:ok, definition} -> definition
      {:error, reason} -> raise ArgumentError, "invalid workflow: #{inspect(reason)}"
    end
  end

  @doc "Runs a workflow with normalized map input and optional context."
  @spec run(module(), map() | keyword(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(workflow_module, input, opts \\ []) when is_atom(workflow_module) and is_list(opts) do
    with {:ok, definition} <- definition(workflow_module),
         {:ok, input} <- normalize_input(input),
         {:ok, context} <- normalize_context(Keyword.get(opts, :context, %{})) do
      case apply(definition.module, :run, [input, context]) do
        {:ok, output} -> {:ok, output}
        {:error, reason} -> {:error, reason}
        output -> {:ok, output}
      end
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  @spec normalize_id(term()) :: {:ok, String.t()} | {:error, term()}
  def normalize_id(id) when is_atom(id) and not is_nil(id) do
    case Atom.to_string(id) do
      "Elixir." <> _module ->
        id
        |> Module.split()
        |> List.last()
        |> Macro.underscore()
        |> normalize_id()

      atom ->
        normalize_id(atom)
    end
  end

  def normalize_id(id) when is_binary(id) do
    id = String.trim(id)

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, id) do
      {:ok, id}
    else
      {:error, {:invalid_workflow_id, id}}
    end
  end

  def normalize_id(id), do: {:error, {:invalid_workflow_id, id}}

  @doc false
  @spec normalize_id!(term()) :: String.t()
  def normalize_id!(id) do
    case normalize_id(id) do
      {:ok, id} -> id
      {:error, reason} -> raise ArgumentError, "invalid workflow id: #{inspect(reason)}"
    end
  end

  defp workflow_id(module) do
    if function_exported?(module, :id, 0), do: apply(module, :id, []), else: module
  end

  defp workflow_description(module) do
    if function_exported?(module, :description, 0), do: apply(module, :description, []), else: nil
  end

  defp parameters_schema(module) do
    if function_exported?(module, :parameters_schema, 0) do
      apply(module, :parameters_schema, [])
    end
  end

  defp normalize_description(nil), do: {:ok, nil}

  defp normalize_description(description) when is_binary(description) do
    case String.trim(description) do
      "" -> {:ok, nil}
      description -> {:ok, description}
    end
  end

  defp normalize_description(description),
    do: {:error, {:invalid_workflow_description, description}}

  defp normalize_parameters_schema(nil), do: {:ok, nil}
  defp normalize_parameters_schema(schema) when is_map(schema), do: {:ok, schema}

  defp normalize_parameters_schema(schema),
    do: {:error, {:invalid_workflow_parameters_schema, schema}}

  defp normalize_input(input) when is_list(input), do: {:ok, Map.new(input)}
  defp normalize_input(input) when is_map(input), do: {:ok, Schema.normalize_attrs(input)}
  defp normalize_input(input), do: {:error, {:invalid_workflow_input, input}}

  defp normalize_context(context) when is_list(context), do: {:ok, Map.new(context)}
  defp normalize_context(context) when is_map(context), do: {:ok, context}
  defp normalize_context(context), do: {:error, {:invalid_workflow_context, context}}
end
