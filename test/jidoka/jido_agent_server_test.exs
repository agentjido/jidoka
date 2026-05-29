defmodule Jidoka.JidoAgentServerTest.Support.LocalTimeAction do
  use Jidoka.Action,
    name: "server_local_time",
    description: "Returns a deterministic local time from a process-hosted agent.",
    schema:
      Zoi.object(%{
        city: Zoi.string() |> Zoi.default("Chicago")
      })

  @impl true
  def run(params, context) do
    city = Map.get(params, :city) || Map.get(params, "city") || "Chicago"

    if pid = context[:test_pid] do
      send(pid, {:server_local_time_called, city})
    end

    {:ok, %{city: city, time: "09:30"}}
  end
end

defmodule Jidoka.JidoAgentServerTest.Support.TimeAgent do
  use Jidoka.Agent

  agent :server_time_agent do
    model %{provider: :test, id: "model"}
    instructions "Use server_local_time when asked for time."
  end

  tools do
    action Jidoka.JidoAgentServerTest.Support.LocalTimeAction
  end
end

defmodule Jidoka.JidoAgentServerTest do
  use ExUnit.Case, async: true

  alias Jidoka.Effect
  alias Jidoka.JidoAgentServerTest.Support.TimeAgent
  alias Jidoka.Turn

  test "runs a Jidoka DSL agent through Jido.AgentServer" do
    id = "jidoka_server_test_#{System.unique_integer([:positive])}"
    test_pid = self()

    llm = fn _intent, %Effect.Journal{} = journal ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "server_local_time",
             arguments: %{"city" => "Chicago"}
           }}

        1 ->
          {:ok, %{type: :final, content: "It is 09:30 in Chicago."}}
      end
    end

    assert {:ok, pid} = TimeAgent.start(id: id)
    assert Jidoka.whereis(id) == pid

    assert {:ok, %Turn.Result{content: "It is 09:30 in Chicago."}} =
             Jidoka.run_turn(pid, "What time is it?",
               llm: llm,
               operation_context: %{test_pid: test_pid}
             )

    assert_receive {:server_local_time_called, "Chicago"}

    assert {:ok, %{status: :completed, result: "It is 09:30 in Chicago."}} =
             Jidoka.await_agent(pid, timeout: 100)

    assert {:ok, "Second turn works by id."} =
             Jidoka.chat(id, "Confirm by id.",
               llm: fn _intent, _journal ->
                 {:ok, %{type: :final, content: "Second turn works by id."}}
               end
             )

    assert :ok = Jidoka.stop_agent(pid)
  end

  defp count_results(%Effect.Journal{results: results}, kind) do
    results
    |> Map.values()
    |> Enum.count(&(&1.kind == kind))
  end
end
