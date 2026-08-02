defmodule Jidoka.Workflow.Resolver do
  @moduledoc false

  alias Jidoka.Workflow.Spec

  @spec definition(module()) :: {:ok, Spec.t()} | {:error, term()}
  def definition(workflow_module) when is_atom(workflow_module) do
    with {:module, _module} <- Code.ensure_compiled(workflow_module),
         {:ok, spec} <- workflow_spec(workflow_module),
         :ok <- validate_runnable(workflow_module, spec) do
      {:ok, spec}
    else
      {:error, reason} -> {:error, {:invalid_workflow_module, workflow_module, reason}}
    end
  end

  def definition(workflow_module), do: {:error, {:invalid_workflow_module, workflow_module}}

  @spec definition!(module()) :: Spec.t()
  def definition!(workflow_module) do
    case definition(workflow_module) do
      {:ok, definition} -> definition
      {:error, reason} -> raise ArgumentError, "invalid workflow: #{inspect(reason)}"
    end
  end

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

  @spec normalize_id!(term()) :: String.t()
  def normalize_id!(id) do
    case normalize_id(id) do
      {:ok, id} -> id
      {:error, reason} -> raise ArgumentError, "invalid workflow id: #{inspect(reason)}"
    end
  end

  defp workflow_spec(workflow_module) do
    cond do
      function_exported?(workflow_module, :__jidoka_workflow__, 0) ->
        case apply(workflow_module, :__jidoka_workflow__, []) do
          %Spec{} = spec -> {:ok, spec}
          other -> {:error, {:invalid_workflow_spec, other}}
        end

      function_exported?(workflow_module, :run, 2) ->
        callback_spec_from_functions(workflow_module)

      true ->
        {:error, :missing_run}
    end
  end

  defp callback_spec_from_functions(workflow_module) do
    with {:ok, id} <- normalize_id(workflow_id(workflow_module)),
         {:ok, description} <- normalize_description(workflow_description(workflow_module)),
         {:ok, parameters_schema} <- normalize_parameters_schema(parameters_schema(workflow_module)) do
      {:ok,
       Spec.new!(
         id: id,
         module: workflow_module,
         description: description,
         mode: :callback,
         parameters_schema: parameters_schema
       )}
    end
  end

  defp validate_runnable(workflow_module, %Spec{mode: :callback}) do
    if function_exported?(workflow_module, :run, 2), do: :ok, else: {:error, :missing_run}
  end

  defp validate_runnable(_workflow_module, %Spec{mode: :dsl}), do: :ok

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
end
