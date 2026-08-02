defmodule Jidoka.Adapter.Runic.Background.Executor do
  @moduledoc false

  @behaviour Runic.Runner.Executor

  @impl true
  def init(opts) do
    {:ok, %{task_supervisor: Keyword.fetch!(opts, :task_supervisor), tasks: []}}
  end

  @impl true
  def dispatch(work_fn, _opts, state) do
    task = Task.Supervisor.async_nolink(state.task_supervisor, work_fn)
    {task.ref, %{state | tasks: [task | state.tasks]}}
  end

  @impl true
  def cleanup(state) do
    Enum.each(state.tasks, &Task.shutdown(&1, :brutal_kill))
    :ok
  end
end
