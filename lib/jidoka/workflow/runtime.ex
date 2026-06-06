defmodule Jidoka.Workflow.Runtime do
  @moduledoc false

  require Runic

  alias Jidoka.Context
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
        outcomes: %{},
        workflow_id: spec.id,
        agent_opts: runtime_opts.agent_opts,
        max_concurrency: runtime_opts.max_concurrency,
        error: nil
      }

      execute_with_timeout(spec, state, runtime_opts)
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec build_workflow(Spec.t()) :: Workflow.t()
  def build_workflow(%Spec{mode: :dsl} = spec) do
    Enum.reduce(spec.steps, Workflow.new(name: spec.id), fn step, workflow ->
      workflow_step =
        Runic.step(
          fn state ->
            run_workflow_step(state, ^spec, ^step)
          end,
          name: step.name
        )

      case Map.get(spec.dependencies, step.name, []) do
        [] -> Workflow.add(workflow, workflow_step)
        dependencies -> Workflow.add(workflow, workflow_step, to: dependencies)
      end
    end)
  end

  defp run_workflow_step(state, %Spec{} = spec, step) do
    StepRunner.run_step(spec, step, merge_workflow_states(state))
  end

  defp final_output(%Workflow{} = workflow, %Spec{} = spec, initial_state) do
    case final_state(workflow, spec, initial_state) do
      {:error, reason} ->
        {:error, reason}

      {:ok, %{error: error}} when not is_nil(error) ->
        {:error, error}

      {:ok, state} ->
        case Value.resolve(spec.output, state) do
          {:ok, output} ->
            {:ok, output}

          {:error, reason} ->
            {:error,
             Jidoka.Error.execution_error("Workflow #{spec.id} output failed.",
               phase: :workflow_output,
               details: %{workflow_id: spec.id, reason: :output_ref, cause: reason}
             )}
        end
    end
  end

  defp final_state(%Workflow{} = workflow, %Spec{} = spec, initial_state) do
    states =
      spec.steps
      |> Enum.flat_map(fn step -> Workflow.raw_productions(workflow, step.name) end)
      |> Enum.filter(&workflow_state?/1)

    case states do
      [] ->
        {:error,
         Jidoka.Error.execution_error("Workflow execution did not produce output.",
           phase: :workflow,
           details: %{workflow_id: spec.id, reason: :missing_output}
         )}

      states ->
        {:ok, merge_workflow_states([initial_state | states])}
    end
  end

  defp merge_workflow_states(%{input: _input, context: _context, steps: _steps} = state), do: state

  defp merge_workflow_states(states) when is_list(states) do
    states
    |> Enum.filter(&workflow_state?/1)
    |> case do
      [] ->
        %{
          input: %{},
          context: Context.from_data!(%{}),
          steps: %{},
          outcomes: %{},
          workflow_id: nil,
          agent_opts: [],
          max_concurrency: nil,
          error: {:invalid_workflow_state_join, states}
        }

      [state | states] ->
        Enum.reduce(states, state, &merge_workflow_state/2)
    end
  end

  defp merge_workflow_states(state) do
    %{
      input: %{},
      context: Context.from_data!(%{}),
      steps: %{},
      outcomes: %{},
      workflow_id: nil,
      agent_opts: [],
      max_concurrency: nil,
      error: {:invalid_workflow_state_join, state}
    }
  end

  defp merge_workflow_state(state, acc) do
    %{
      acc
      | steps: Map.merge(acc.steps, state.steps),
        outcomes: Map.merge(Map.get(acc, :outcomes, %{}), Map.get(state, :outcomes, %{})),
        error: acc.error || state.error
    }
  end

  defp workflow_state?(%{input: _input, context: _context, steps: _steps}), do: true
  defp workflow_state?(_state), do: false

  defp execute_with_timeout(%Spec{} = spec, state, runtime_opts) do
    timeout = runtime_opts.timeout

    task =
      Task.async(fn ->
        safe_execute(spec, state, runtime_opts)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        {:error,
         Jidoka.Error.execution_error("Workflow #{spec.id} timed out.",
           phase: :workflow,
           details: %{workflow_id: spec.id, reason: :timeout, timeout: timeout}
         )}
    end
  end

  defp safe_execute(%Spec{} = spec, state, runtime_opts) do
    spec
    |> build_workflow()
    |> Workflow.react_until_satisfied(state, runic_opts(runtime_opts))
    |> final_output(spec, state)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_opts(opts) do
    with {:ok, context} <- normalize_context(Keyword.get(opts, :context, %{})),
         {:ok, timeout} <- normalize_timeout(Keyword.get(opts, :timeout, 30_000)),
         {:ok, async} <- normalize_async(Keyword.get(opts, :async, false)),
         {:ok, max_concurrency} <- normalize_max_concurrency(Keyword.get(opts, :max_concurrency)),
         {:ok, agent_opts} <- normalize_agent_opts(Keyword.get(opts, :agent_opts, [])) do
      {:ok,
       %{
         context: context,
         timeout: timeout,
         async: async,
         max_concurrency: max_concurrency,
         agent_opts: agent_opts
       }}
    end
  end

  defp runic_opts(%{timeout: timeout, async: async, max_concurrency: max_concurrency}) do
    [deadline_ms: timeout]
    |> Keyword.put(:async, async)
    |> Keyword.put(:timeout, timeout)
    |> maybe_put_max_concurrency(max_concurrency)
  end

  defp normalize_context(%Context{} = context), do: {:ok, context}

  defp normalize_context(context) when is_list(context) or is_map(context) do
    case Context.from_data(context) do
      {:ok, context} -> {:ok, context}
      {:error, _reason} -> invalid_context(context)
    end
  end

  defp normalize_context(context), do: invalid_context(context)

  defp invalid_context(context) do
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

  defp normalize_async(async) when is_boolean(async), do: {:ok, async}

  defp normalize_async(async) do
    {:error,
     Jidoka.Error.validation_error("Invalid workflow async option: expected a boolean.",
       field: :async,
       value: async,
       details: %{reason: :invalid_workflow_async}
     )}
  end

  defp normalize_max_concurrency(nil), do: {:ok, nil}

  defp normalize_max_concurrency(max_concurrency)
       when is_integer(max_concurrency) and max_concurrency > 0 do
    {:ok, max_concurrency}
  end

  defp normalize_max_concurrency(max_concurrency) do
    {:error,
     Jidoka.Error.validation_error("Invalid workflow max_concurrency: expected a positive integer.",
       field: :max_concurrency,
       value: max_concurrency,
       details: %{reason: :invalid_workflow_max_concurrency}
     )}
  end

  defp maybe_put_max_concurrency(opts, nil), do: opts
  defp maybe_put_max_concurrency(opts, max_concurrency), do: Keyword.put(opts, :max_concurrency, max_concurrency)

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

  defp normalize_input(input) when is_list(input) do
    if Keyword.keyword?(input) do
      {:ok, Map.new(input)}
    else
      invalid_input(input)
    end
  end

  defp normalize_input(input) when is_map(input), do: {:ok, input}

  defp normalize_input(input), do: invalid_input(input)

  defp invalid_input(input) do
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
      if Value.has_equivalent_key?(Context.data(context), key) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          Jidoka.Error.validation_error("Missing workflow context key `#{key}`.",
            field: :context,
            value: Context.data(context),
            details: %{workflow_id: spec.id, reason: :missing_context, key: key}
          )}}
      end
    end)
  end
end
