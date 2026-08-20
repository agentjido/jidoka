defmodule Jidoka.Adapter.Runic.OperationBatch do
  @moduledoc false

  require Runic

  alias Jidoka.Config
  alias Jidoka.Effect
  alias Jidoka.Error
  alias Jidoka.Operation.Continuation
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.OperationInvoker
  alias Jidoka.Turn
  alias Runic.Workflow

  @spec execute(Turn.State.t(), [Effect.Intent.t()], Capabilities.t(), Effect.Journal.t(), keyword()) ::
          {:ok, %{String.t() => Effect.Result.t() | Continuation.t()}} | {:error, term()}
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
        deadline_ms: remaining_turn_deadline(state, opts),
        timeout: :infinity
      )

    intents
    |> Enum.zip(step_names)
    |> Enum.reduce_while({:ok, %{}}, fn {intent, step_name}, {:ok, acc} ->
      case workflow |> Workflow.raw_productions(step_name) |> List.last() do
        %Effect.Result{} = result ->
          {:cont, {:ok, Map.put(acc, intent.id, result)}}

        %Continuation{} = continuation ->
          {:cont, {:ok, Map.put(acc, intent.id, continuation)}}

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
    case before_operation_call(intent, journal, opts) do
      {:ok, journal} ->
        execute_operation_batch_step(state, intent, capabilities, journal, opts)

      {:error, reason} ->
        {:operation_group_checkpoint_failed, reason}
    end
  end

  defp execute_operation_batch_step(state, intent, capabilities, journal, opts) do
    case call_operation_capability(state, intent, capabilities, journal, opts) do
      {:ok, %Effect.Result{} = result} -> checkpoint_operation_batch_result(intent, result, opts)
      {:hibernate, %Continuation{} = continuation} -> continuation
    end
  end

  defp checkpoint_operation_batch_result(intent, result, opts) do
    case after_operation_result(intent, result, opts) do
      :ok -> result
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

  defp remaining_turn_deadline(
         %Turn.State{plan: %{timeout_ms: timeout_ms}, started_at_ms: started_at_ms},
         opts
       )
       when is_integer(timeout_ms) and is_integer(started_at_ms) do
    max(1, timeout_ms - (clock_ms(opts) - started_at_ms))
  end

  defp remaining_turn_deadline(%Turn.State{plan: %{timeout_ms: timeout_ms}}, _opts)
       when is_integer(timeout_ms),
       do: timeout_ms

  defp clock_ms(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _clock -> System.system_time(:millisecond)
    end
  end

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
