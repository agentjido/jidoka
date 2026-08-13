defmodule Jidoka.Adapter.Runic.OperationBatch do
  @moduledoc false

  require Runic

  alias Jidoka.Config
  alias Jidoka.Effect
  alias Jidoka.Error
  alias Jidoka.Runtime.CapabilityInvoker
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.OperationInvoker
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
        deadline_ms: batch_timeout(state, opts),
        timeout: batch_timeout(state, opts)
      )

    intents
    |> Enum.zip(step_names)
    |> Enum.reduce_while({:ok, %{}}, fn {intent, step_name}, {:ok, acc} ->
      case workflow |> Workflow.raw_productions(step_name) |> List.last() do
        %Effect.Result{} = result ->
          {:cont, {:ok, Map.put(acc, intent.id, result)}}

        {:operation_group_checkpoint_failed, reason} ->
          {:halt, {:error, reason}}

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
    with {:ok, journal} <- before_operation_call(intent, journal, opts),
         {:ok, %Effect.Result{} = result} <-
           call_operation_capability(state, intent, capabilities, journal, opts),
         :ok <- after_operation_result(intent, result, opts) do
      result
    else
      {:error, reason} -> {:operation_group_checkpoint_failed, reason}
    end
  end

  defp call_operation_capability(
         %Turn.State{} = state,
         %Effect.Intent{kind: :operation} = intent,
         %Capabilities{} = capabilities,
         journal,
         opts
       ) do
    OperationInvoker.invoke(state, intent, capabilities, journal, opts)
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

  defp batch_timeout(state, opts), do: CapabilityInvoker.capability_timeout(state, opts)

  defp before_operation_call(intent, journal, opts) do
    case Keyword.get(opts, :operation_group_before_call) do
      callback when is_function(callback, 1) -> callback.(intent)
      _callback -> {:ok, journal}
    end
  end

  defp after_operation_result(intent, result, opts) do
    case Keyword.get(opts, :operation_group_after_result) do
      callback when is_function(callback, 2) -> callback.(intent, result)
      _callback -> :ok
    end
  end

  defp effect_operation(%Effect.Intent{kind: :operation, payload: payload}) do
    Map.get(payload, :name) || Map.get(payload, "name")
  end
end
