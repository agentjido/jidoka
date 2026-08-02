defmodule Jidoka.Workflow.Background do
  @moduledoc """
  Runs durable declarative workflows in the background.

  This module is the Jidoka use-case facade. The Runic process and event-store
  details stay in `Jidoka.Adapter.Runic.Background`.
  """

  alias Jidoka.Adapter.Runic.Background, as: RunicBackground
  alias Jidoka.Workflow.{Run, RunEvent}

  @type runner :: atom()

  @doc "Returns a child specification for a named background workflow runner."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(opts), to: RunicBackground

  @doc "Starts a supervised background workflow runner."
  @spec start_link(keyword()) :: Supervisor.on_start()
  defdelegate start_link(opts), to: RunicBackground

  @doc "Submits a declarative workflow and returns its stable run ID."
  @spec submit(runner(), module(), map() | keyword(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defdelegate submit(runner, workflow_module, input, opts \\ []), to: RunicBackground

  @doc "Returns the current public run view by stable ID."
  @spec get(runner(), String.t()) :: {:ok, Run.t()} | {:error, term()}
  defdelegate get(runner, run_id), to: RunicBackground

  @doc "Waits for one background run to reach a terminal or recoverable state."
  @spec await(runner(), String.t(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  defdelegate await(runner, run_id, opts \\ []), to: RunicBackground

  @doc "Returns portable events for one background run."
  @spec events(runner(), String.t()) :: {:ok, [RunEvent.t()]} | {:error, term()}
  defdelegate events(runner, run_id), to: RunicBackground

  @doc "Restarts one recoverable background run from stored events."
  @spec recover(runner(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defdelegate recover(runner, run_id, opts \\ []), to: RunicBackground

  @doc "Stops one background run and keeps its persisted events."
  @spec stop(runner(), String.t()) :: :ok | {:error, term()}
  defdelegate stop(runner, run_id), to: RunicBackground
end
