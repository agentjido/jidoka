defmodule Jidoka.Runtime.OperationBatch do
  @moduledoc false

  require Runic

  alias Jidoka.Config
  alias Jidoka.Effect
  alias Jidoka.Error
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.Context, as: RuntimeContext
  alias Jidoka.Turn
  alias Runic.Workflow

  @spec execute(Turn.State.t(), [Effect.Intent.t()], Capabilities.t(), Effect.Journal.t(), keyword()) ::
          {:ok, %{String.t() => Effect.Result.t()}} | {:error, term()}
  def execute(%Turn.State{} = state, intents, %Capabilities{} = capabilities, %Effect.Journal{} = journal, opts)
      when is_list(intents) do
    step_names = operation_batch_step_names(intents)

    workflow =
      intents
      |> Enum.zip(step_names)
      |> Enum.reduce(Workflow.new(name: :jidoka_operation_batch), fn {intent, step_name}, workflow ->
        workflow_step =
          Runic.step(
            fn _state ->
              call_operation_batch_step(^state, ^intent, ^capabilities, ^journal, ^opts)
            end,
            name: step_name
          )

        Workflow.add(workflow, workflow_step)
      end)

    workflow =
      Workflow.react_until_satisfied(workflow, %{},
        async: true,
        max_concurrency: max_parallel_operations(opts),
        timeout: :infinity
      )

    intents
    |> Enum.zip(step_names)
    |> Enum.reduce_while({:ok, %{}}, fn {intent, step_name}, {:ok, acc} ->
      case workflow |> Workflow.raw_productions(step_name) |> List.last() do
        %Effect.Result{} = result ->
          {:cont, {:ok, Map.put(acc, intent.id, result)}}

        other ->
          {:halt,
           {:error,
            Error.normalize({:missing_operation_batch_result, intent.id, other},
              operation: effect_operation(intent),
              phase: :effect,
              intent_id: intent.id,
              effect_kind: intent.kind
            )}}
      end
    end)
  rescue
    exception -> {:error, Error.normalize(exception, operation: :operation, phase: :effect)}
  catch
    kind, reason -> {:error, Error.normalize({kind, reason}, operation: :operation, phase: :effect)}
  end

  defp call_operation_batch_step(
         %Turn.State{} = state,
         %Effect.Intent{} = intent,
         %Capabilities{} = capabilities,
         %Effect.Journal{} = journal,
         opts
       ) do
    case call_operation_capability(state, intent, capabilities, journal, opts) do
      {:ok, %Effect.Result{} = result} -> result
    end
  end

  defp call_operation_capability(
         %Turn.State{} = state,
         %Effect.Intent{kind: :operation} = intent,
         %Capabilities{operations: operations},
         journal,
         opts
       ) do
    with {:ok, ctx} <- RuntimeContext.operation(state, intent, opts) do
      case invoke_capability(operations, intent, journal, ctx) do
        {:ok, output} ->
          {:ok, Effect.Result.ok(intent, output)}

        {:error, reason} ->
          {:ok, Effect.Result.error(intent, normalize_capability_error(reason, intent))}

        other ->
          {:ok,
           Effect.Result.error(
             intent,
             normalize_capability_error({:invalid_capability_result, other}, intent)
           )}
      end
    else
      {:error, reason} ->
        {:ok, Effect.Result.error(intent, normalize_capability_error(reason, intent))}
    end
  end

  defp invoke_capability(capability, intent, journal, ctx) do
    capability.(intent, journal, ctx)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_capability_error(reason, %Effect.Intent{} = intent) do
    Error.normalize(reason,
      operation: intent.kind,
      phase: :effect,
      intent_id: intent.id,
      effect_kind: intent.kind
    )
  end

  defp operation_batch_step_names(intents) do
    intents
    |> Enum.with_index()
    |> Enum.map(fn {_intent, index} -> "operation_#{index}" end)
  end

  defp max_parallel_operations(opts) do
    opts
    |> Keyword.get(:max_parallel_operations, Config.default_max_parallel_operations())
    |> Config.normalize_positive_integer!(:max_parallel_operations)
  end

  defp effect_operation(%Effect.Intent{kind: :operation, payload: payload}) do
    Map.get(payload, :name) || Map.get(payload, "name")
  end
end
