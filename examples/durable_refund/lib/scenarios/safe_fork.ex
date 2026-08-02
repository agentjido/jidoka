defmodule JidokaExamples.DurableRefund.Scenarios.SafeFork do
  @moduledoc false

  alias Jidoka.Harness.Session
  alias Jidoka.Harness.Replay
  alias Jidoka.Harness.Store.InMemory
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn
  alias JidokaExamples.DurableRefund.Agent
  alias JidokaExamples.DurableRefund.ScriptedLLM

  def run(opts \\ []) do
    store = Keyword.get_lazy(opts, :fork_store, &in_memory_store/0)
    source_id = Keyword.get(opts, :source_session_id, "durable-refund-source")
    branch_id = Keyword.get(opts, :branch_session_id, "durable-refund-branch")

    with {:ok, %Session{}} <- Jidoka.Session.start(Agent, source_id, store: store),
         {:hibernate, %Session{} = source, %AgentSnapshot{} = snapshot} <-
           Jidoka.Session.run(source_id, "Choose a refund path",
             store: store,
             llm: ScriptedLLM.final("unused"),
             checkpoint: :after_prompt
           ),
         {:ok, %Session{} = branch} <-
           Jidoka.Session.fork(source_id,
             store: store,
             session_id: branch_id,
             snapshot: snapshot
           ),
         {:ok, %Session{} = finished_source, %Turn.Result{} = source_result} <-
           Jidoka.Session.resume(source_id,
             store: store,
             llm: ScriptedLLM.final("manual review path")
           ),
         {:ok, %Session{} = finished_branch, %Turn.Result{} = branch_result} <-
           Jidoka.Session.resume(branch_id,
             store: store,
             llm: ScriptedLLM.final("automatic refund path")
           ),
         {:ok, %Replay{} = replay} <- Jidoka.Session.replay(finished_source) do
      {:ok,
       %{
         branch: finished_branch,
         branch_answer: branch_result.content,
         branch_before_resume: branch,
         source: finished_source,
         source_answer: source_result.content,
         source_before_fork: source,
         source_replay: replay
       }}
    end
  end

  defp in_memory_store do
    {:ok, pid} = InMemory.start_link()
    {InMemory, pid: pid}
  end
end
