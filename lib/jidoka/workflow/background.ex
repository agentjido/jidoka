defmodule Jidoka.Workflow.Background do
  @moduledoc """
  Durable background execution for declarative Jidoka workflows.

  This module is a small public adapter around `Runic.Runner`. The runner owns
  supervised tasks, event checkpoints, worker recovery, and its configured
  store. A caller can reconnect with only the runner name and stable run ID.

  Start it in an application supervision tree:

      {Jidoka.Workflow.Background, name: MyApp.WorkflowRunner}

  Configure a separately supervised `Runic.Runner.Store.Mnesia` when runs must
  survive a VM restart. The default Runic ETS store survives worker restarts in
  the current VM.
  """

  alias Jidoka.Workflow
  alias Jidoka.Workflow.Background.Executor
  alias Jidoka.Workflow.{Run, RunEvent, Spec}
  alias Jidoka.Workflow.Runtime
  alias Runic.Runner

  @type runner :: atom()

  @doc "Returns a child specification for a named background workflow runner."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Starts a supervised background workflow runner."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Runner.start_link(opts)

  @doc "Submits a declarative workflow and returns its stable run ID."
  @spec submit(runner(), module(), map() | keyword(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def submit(runner, workflow_module, input, opts \\ [])
      when is_atom(runner) and is_atom(workflow_module) and is_list(opts) do
    with {:ok, spec} <- Workflow.definition(workflow_module),
         :ok <- require_dsl_workflow(spec),
         {:ok, run_id} <- run_id(opts),
         {:ok, state, runtime_opts} <- Runtime.prepare(spec, input, opts),
         {:ok, _pid} <- start_run(runner, run_id, Runtime.build_workflow(spec), runtime_opts, opts),
         :ok <- Runner.run(runner, run_id, state) do
      {:ok, run_id}
    end
  end

  @doc "Returns the current public run view by stable ID."
  @spec get(runner(), String.t()) :: {:ok, Run.t()} | {:error, term()}
  def get(runner, run_id) when is_atom(runner) and is_binary(run_id) do
    case get_active_workflow(runner, run_id) do
      {:ok, workflow} ->
        event_count = event_count(runner, run_id)
        Runtime.inspect_run(workflow, run_id, event_count)

      {:error, :not_found} ->
        recoverable_view(runner, run_id)

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Waits until a background workflow reaches a terminal state."
  @spec await(runner(), String.t(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def await(runner, run_id, opts \\ []) when is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    interval = Keyword.get(opts, :interval, 5)
    deadline = System.monotonic_time(:millisecond) + timeout
    await_until(runner, run_id, deadline, interval)
  end

  @doc "Returns safe persisted lifecycle events for a run."
  @spec events(runner(), String.t()) :: {:ok, [RunEvent.t()]} | {:error, term()}
  def events(runner, run_id) when is_atom(runner) and is_binary(run_id) do
    with {:ok, raw_events} <- stream_events(runner, run_id) do
      workflow = active_workflow(runner, run_id)

      events =
        raw_events
        |> Enum.with_index(1)
        |> Enum.map(fn {event, sequence} -> project_event(event, workflow, run_id, sequence) end)

      {:ok, events}
    end
  end

  @doc "Recovers a stopped or crashed worker from its persisted event stream."
  @spec recover(runner(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def recover(runner, run_id, opts \\ []) when is_atom(runner) and is_binary(run_id) and is_list(opts) do
    with {:ok, run} <- get(runner, run_id),
         :ok <- require_recoverable(run),
         {:ok, _rehydrated} <- Runner.resume(runner, run_id, opts),
         {:ok, workflow} <- Runner.get_workflow(runner, run_id),
         {:ok, state} <- Runtime.recovery_state(workflow, opts),
         :ok <- Runner.stop(runner, run_id, persist: false),
         {:ok, pid} <-
           Runner.start_workflow(
             runner,
             run_id,
             Runtime.build_workflow(state.workflow_spec),
             max_concurrency: state.max_concurrency || System.schedulers_online(),
             checkpoint_strategy: Keyword.get(opts, :checkpoint_strategy, :every_cycle),
             executor: Executor,
             executor_opts: [task_supervisor: Module.concat(runner, TaskSupervisor)]
           ),
         :ok <- Runner.run(runner, run_id, state) do
      {:ok, pid}
    end
  end

  @doc "Stops one worker after it checkpoints its current workflow state."
  @spec stop(runner(), String.t()) :: :ok | {:error, term()}
  def stop(runner, run_id), do: Runner.stop(runner, run_id, persist: true)

  defp start_run(runner, run_id, workflow, runtime_opts, opts) do
    runner_opts = [
      max_concurrency: runtime_opts.max_concurrency || System.schedulers_online(),
      checkpoint_strategy: Keyword.get(opts, :checkpoint_strategy, :every_cycle),
      executor: Executor,
      executor_opts: [task_supervisor: Module.concat(runner, TaskSupervisor)]
    ]

    Runner.start_workflow(runner, run_id, workflow, runner_opts)
  end

  defp run_id(opts) do
    case Keyword.get(opts, :run_id) do
      nil -> Jidoka.Id.generate("run", Keyword.get(opts, :id_generator))
      run_id when is_binary(run_id) and run_id != "" -> {:ok, run_id}
      run_id -> {:error, {:invalid_background_run_id, run_id}}
    end
  end

  defp require_dsl_workflow(%Jidoka.Workflow.Spec{mode: :dsl}), do: :ok
  defp require_dsl_workflow(spec), do: {:error, {:background_workflow_requires_dsl, spec.id}}

  defp await_until(runner, run_id, deadline, interval) do
    case get(runner, run_id) do
      {:ok, %Run{} = run} ->
        cond do
          Run.terminal?(run) ->
            {:ok, run}

          System.monotonic_time(:millisecond) >= deadline ->
            {:error, {:background_run_timeout, run_id}}

          true ->
            Process.sleep(interval)
            await_until(runner, run_id, deadline, interval)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp recoverable_view(runner, run_id) do
    case stream_events(runner, run_id) do
      {:ok, raw_events} when raw_events != [] ->
        inspect_persisted_run(raw_events, runner, run_id)

      {:ok, []} ->
        {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  defp event_count(runner, run_id) do
    case events(runner, run_id) do
      {:ok, events} -> length(events)
      {:error, _reason} -> 0
    end
  end

  defp active_workflow(runner, run_id) do
    case get_active_workflow(runner, run_id) do
      {:ok, workflow} -> workflow
      {:error, _reason} -> nil
    end
  end

  defp get_active_workflow(runner, run_id) do
    Runner.get_workflow(runner, run_id)
  catch
    :exit, {:noproc, _call} -> {:error, :not_found}
    :exit, {:normal, _call} -> {:error, :not_found}
  end

  defp stream_events(runner, run_id) do
    {store, store_state} = Runner.get_store(runner)

    if Runic.Runner.Store.supports_stream?(store) do
      case store.stream(run_id, store_state) do
        {:ok, stream} -> {:ok, Enum.to_list(stream)}
        {:error, _reason} = error -> error
      end
    else
      {:error, :event_stream_not_supported}
    end
  end

  defp workflow_id_from_events(events) do
    Enum.find_value(events, "unknown", fn
      %Runic.Workflow.ComponentAdded{
        closure: %Runic.Closure{bindings: %{spec: %Spec{id: workflow_id}}}
      } ->
        workflow_id

      _event ->
        nil
    end)
  end

  defp inspect_persisted_run(raw_events, runner, run_id) do
    workflow = rehydrate_events(raw_events, runner)
    workflow_id = workflow_id_from_events(raw_events)

    case Runtime.inspect_run(workflow, run_id, length(raw_events)) do
      {:ok, %Run{status: status} = run} when status in [:completed, :failed, :hibernated] ->
        {:ok, ensure_workflow_id(run, workflow_id)}

      {:ok, %Run{} = run} ->
        run = ensure_workflow_id(run, workflow_id)
        {:ok, %{run | status: :recoverable, output: nil, error: nil}}
    end
  rescue
    _exception -> recoverable_fallback(raw_events, run_id)
  catch
    _kind, _reason -> recoverable_fallback(raw_events, run_id)
  end

  defp recoverable_fallback(raw_events, run_id) do
    {:ok,
     %Run{
       id: run_id,
       workflow_id: workflow_id_from_events(raw_events),
       status: :recoverable,
       output: nil,
       error: nil,
       outcomes: %{},
       event_count: length(raw_events)
     }}
  end

  defp require_recoverable(%Run{status: :recoverable}), do: :ok
  defp require_recoverable(%Run{status: status}), do: {:error, {:background_run_not_recoverable, status}}

  defp ensure_workflow_id(%Run{workflow_id: id} = run, fallback) when id in [nil, ""],
    do: %{run | workflow_id: fallback}

  defp ensure_workflow_id(%Run{} = run, _fallback), do: run

  defp rehydrate_events(events, runner) do
    if Enum.any?(events, &match?(%Runic.Workflow.Events.FactProduced{value: nil}, &1)) do
      workflow = Runic.Workflow.from_events(events, nil, fact_mode: :ref)

      fact_hashes =
        for {hash, %Runic.Workflow.FactRef{}} <- workflow.graph.vertices,
            into: MapSet.new(),
            do: hash

      resolver = Runic.Workflow.FactResolver.new(Runner.get_store(runner))
      {workflow, _resolver} = Runic.Workflow.Rehydration.resolve_hot(workflow, fact_hashes, resolver)
      workflow
    else
      Runic.Workflow.from_events(events)
    end
  end

  defp project_event(event, workflow, run_id, sequence) do
    %RunEvent{
      run_id: run_id,
      sequence: sequence,
      type: event_type(event),
      component: event_component(event, workflow)
    }
  end

  defp event_type(%module{}) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp event_component(%{name: name}, _workflow) when is_atom(name) or is_binary(name), do: name

  defp event_component(%{node_hash: hash}, %Runic.Workflow{components: components}) do
    Enum.find_value(components, fn {name, component_hash} -> if component_hash == hash, do: name end)
  end

  defp event_component(_event, _workflow), do: nil
end
