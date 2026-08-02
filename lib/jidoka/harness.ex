defmodule Jidoka.Harness do
  @moduledoc """
  Compatibility facade for Jidoka execution use cases.

  Direct turns are owned by `Jidoka.Turn.Execution`. Durable sessions are
  owned by `Jidoka.Session.Execution`. New internal code must call those owner
  modules directly.
  """

  alias Jidoka.Memory
  alias Jidoka.Review.Execution, as: ReviewExecution
  alias Jidoka.Session.Data
  alias Jidoka.Session.Execution, as: SessionExecution
  alias Jidoka.Session.Replay
  alias Jidoka.Session.Store
  alias Jidoka.Snapshot
  alias Jidoka.Turn
  alias Jidoka.Turn.Execution, as: TurnExecution

  @type agent_input :: TurnExecution.plan_input()
  @type plan_input :: TurnExecution.plan_input()
  @type request_input :: TurnExecution.request_input()
  @type runtime_opts :: keyword()
  @type session_input :: SessionExecution.session_input()
  @type run_result :: TurnExecution.result()
  @type session_run_result :: SessionExecution.session_run_result()

  @doc "Runs one direct agent turn."
  @spec run_turn(plan_input(), request_input(), runtime_opts()) :: run_result()
  def run_turn(spec_or_plan, request_input, opts \\ []),
    do: TurnExecution.run(spec_or_plan, request_input, opts)

  @doc "Resumes one hibernated snapshot."
  @spec resume(Snapshot.t() | String.t(), runtime_opts()) :: run_result()
  def resume(snapshot_input, opts \\ []), do: TurnExecution.resume(snapshot_input, opts)

  @doc "Starts durable session data."
  @spec start_session(plan_input(), runtime_opts()) :: {:ok, Data.t()} | {:error, term()}
  def start_session(spec_or_plan, opts \\ []), do: SessionExecution.start_session(spec_or_plan, opts)

  @doc "Runs one durable session turn."
  @spec run_session(session_input(), request_input(), runtime_opts()) :: session_run_result()
  def run_session(session_input, request_input, opts \\ []),
    do: SessionExecution.run_session(session_input, request_input, opts)

  @doc "Resumes the latest snapshot in a durable session."
  @spec resume_session(session_input(), runtime_opts()) :: session_run_result()
  def resume_session(session_input, opts \\ []), do: SessionExecution.resume_session(session_input, opts)

  @doc "Recovers one stored session after lease expiry."
  @spec recover_session(String.t(), runtime_opts()) :: session_run_result()
  def recover_session(session_id, opts \\ []), do: SessionExecution.recover_session(session_id, opts)

  @doc "Forks one session from safe snapshot evidence."
  @spec fork_session(session_input(), runtime_opts()) :: {:ok, Data.t()} | {:error, term()}
  def fork_session(session_input, opts \\ []), do: SessionExecution.fork_session(session_input, opts)

  @doc "Lists pending review requests."
  @spec pending_reviews(Data.t() | Store.store()) ::
          {:ok, [Jidoka.Review.Request.t()]} | {:error, term()}
  def pending_reviews(session_or_store), do: ReviewExecution.pending(session_or_store)

  @doc "Builds replay data for a session or snapshot."
  @spec replay(Data.t() | Snapshot.t()) :: {:ok, Replay.t()} | {:error, term()}
  def replay(session_or_snapshot), do: SessionExecution.replay(session_or_snapshot)

  @doc "Writes one memory entry."
  @spec write_memory(plan_input() | Data.t(), String.t(), runtime_opts()) ::
          {:ok, Memory.WriteResult.t()} | {:error, term()}
  def write_memory(spec_or_session, content, opts \\ []),
    do: SessionExecution.write_memory(spec_or_session, content, opts)

  @doc false
  @spec plan(plan_input()) :: {:ok, Turn.Plan.t()} | {:error, term()}
  def plan(spec_input), do: TurnExecution.plan(spec_input)

  @doc false
  defdelegate store_get_session(store, session_id), to: Store, as: :get_session

  @doc false
  defdelegate store_list_sessions(store), to: Store, as: :list_sessions

  @doc false
  def store_list_recoverable(store, opts \\ []), do: Store.list_recoverable(store, opts)
end
