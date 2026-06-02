defmodule Jidoka.Workflow.Runtime do
  @moduledoc false

  require Runic

  alias Jidoka.Workflow.Runtime.{StepRunner, Value}
  alias Jidoka.Workflow.Spec
  alias Runic.Workflow

  @spec run(Spec.t(), map() | keyword(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(%Spec{mode: :dsl} = spec, input, opts \\ []) when is_list(opts) do
    with {:ok, runtime_opts} <- normalize_opts(opts),
         {:ok, input} <- parse_input(spec, input),
         :ok <- validate_context_refs(spec, runtime_opts.context) do
      state = %{
        input: input,
        context: runtime_opts.context,
        steps: %{},
        workflow_id: spec.id,
        agent_opts: runtime_opts.agent_opts,
        error: nil
      }

      spec
      |> build_workflow()
      |> Workflow.react_until_satisfied(state, deadline_ms: runtime_opts.timeout)
      |> final_output(spec)
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec build_workflow(Spec.t()) :: Workflow.t()
  def build_workflow(%Spec{mode: :dsl} = spec) do
    run_workflow =
      Runic.step(
        fn state ->
          Enum.reduce(spec.steps, state, fn step, state ->
            StepRunner.run_step(spec, step, state)
          end)
        end,
        name: :run_workflow
      )

    Workflow.new(name: spec.id)
    |> Workflow.add(run_workflow)
  end

  defp final_output(%Workflow{} = workflow, %Spec{} = spec) do
    case workflow |> Workflow.raw_productions(:run_workflow) |> List.last() do
      nil ->
        {:error,
         Jidoka.Error.execution_error("Workflow execution did not produce output.",
           phase: :workflow,
           details: %{workflow_id: spec.id, reason: :missing_output}
         )}

      %{error: error} when not is_nil(error) ->
        {:error, error}

      state ->
        Value.resolve(spec.output, state)
    end
  end

  defp normalize_opts(opts) do
    with {:ok, context} <- normalize_context(Keyword.get(opts, :context, %{})),
         {:ok, timeout} <- normalize_timeout(Keyword.get(opts, :timeout, 30_000)),
         {:ok, agent_opts} <- normalize_agent_opts(Keyword.get(opts, :agent_opts, [])) do
      {:ok, %{context: context, timeout: timeout, agent_opts: agent_opts}}
    end
  end

  defp normalize_context(context) when is_list(context), do: {:ok, Map.new(context)}
  defp normalize_context(context) when is_map(context), do: {:ok, context}

  defp normalize_context(context) do
    {:error,
     Jidoka.Error.validation_error("Invalid workflow context: expected a map or keyword list.",
       field: :context,
       value: context,
       details: %{reason: :invalid_workflow_context}
     )}
  end

  defp normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: {:ok, timeout}

  defp normalize_timeout(timeout) do
    {:error,
     Jidoka.Error.validation_error("Invalid workflow timeout: expected a positive integer.",
       field: :timeout,
       value: timeout,
       details: %{reason: :invalid_workflow_timeout}
     )}
  end

  defp normalize_agent_opts(opts) when is_list(opts), do: {:ok, opts}

  defp normalize_agent_opts(opts) do
    {:error,
     Jidoka.Error.validation_error("Invalid workflow agent options: expected a keyword list.",
       field: :agent_opts,
       value: opts,
       details: %{reason: :invalid_workflow_agent_opts}
     )}
  end

  defp parse_input(%Spec{} = spec, input) do
    with {:ok, input} <- normalize_input(input) do
      case Zoi.parse(spec.input_schema, normalize_value_for_schema(spec.input_schema, input)) do
        {:ok, %{} = parsed} ->
          {:ok, parsed}

        {:ok, value} ->
          {:error,
           Jidoka.Error.config_error("Workflow input schema must parse to a map.",
             field: :input_schema,
             value: value,
             details: %{workflow_id: spec.id, reason: :expected_map_result}
           )}

        {:error, reason} ->
          {:error,
           Jidoka.Error.validation_error("Invalid workflow input.",
             field: :input,
             value: input,
             details: %{workflow_id: spec.id, reason: :schema, cause: reason}
           )}
      end
    end
  end

  defp normalize_input(input) when is_list(input), do: {:ok, Map.new(input)}
  defp normalize_input(input) when is_map(input), do: {:ok, input}

  defp normalize_input(input) do
    {:error,
     Jidoka.Error.validation_error("Invalid workflow input: expected a map or keyword list.",
       field: :input,
       value: input,
       details: %{reason: :invalid_workflow_input}
     )}
  end

  defp normalize_value_for_schema(%Zoi.Types.Map{fields: fields}, %{} = value)
       when is_list(fields) do
    Enum.reduce(fields, value, fn {field, field_schema}, acc ->
      string_field = Atom.to_string(field)

      cond do
        Map.has_key?(acc, field) ->
          Map.update!(acc, field, &normalize_value_for_schema(field_schema, &1))

        Map.has_key?(acc, string_field) ->
          field_value = normalize_value_for_schema(field_schema, Map.fetch!(acc, string_field))

          acc
          |> Map.delete(string_field)
          |> Map.put(field, field_value)

        true ->
          acc
      end
    end)
  end

  defp normalize_value_for_schema(%Zoi.Types.Array{inner: inner}, value) when is_list(value) do
    Enum.map(value, &normalize_value_for_schema(inner, &1))
  end

  defp normalize_value_for_schema(_schema, value), do: value

  defp validate_context_refs(%Spec{} = spec, context) do
    Enum.reduce_while(spec.context_refs, :ok, fn key, :ok ->
      if Value.has_equivalent_key?(context, key) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          Jidoka.Error.validation_error("Missing workflow context key `#{key}`.",
            field: :context,
            value: context,
            details: %{workflow_id: spec.id, reason: :missing_context, key: key}
          )}}
      end
    end)
  end
end
