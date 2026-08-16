defmodule JidokaShowcaseWeb.SupportAgentLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias JidokaExamples.SupportAgent.Agent
  alias JidokaShowcaseWeb.AgentLive
  alias JidokaShowcaseWeb.SupportAgentLive.View

  @endpoint JidokaShowcaseWeb.Endpoint

  test "mounts the cataloged agent and resets it without a provider call" do
    assert View.agent_module(%{}) == Agent
    assert {:ok, view, html} = live(build_conn(), "/agents/support")

    assert html =~ "Support Agent"
    assert html =~ "Ask about order A1001"

    first_pid = JidokaShowcase.Jido.whereis(Agent.spec().id)
    assert is_pid(first_pid)

    html = view |> element("button", "Source") |> render_click()
    assert html =~ "examples/support_agent/lib/agent.ex"
    assert html =~ "Action"
    assert html =~ "Control"
    assert html =~ "AgentView"
    assert html =~ "LiveView"

    html = view |> element("button", "New session") |> render_click()
    assert html =~ "Start with the sample order."

    reset_pid = JidokaShowcase.Jido.whereis(Agent.spec().id)
    assert is_pid(reset_pid)
    assert reset_pid != first_pid
  end

  test "a worker crash clears the active request and shows an error" do
    request_id = "showcase-worker-crash"
    socket = worker_socket(request_id)

    socket =
      AgentLive.start_turn_worker(socket, View, request_id, "test:model", fn ->
        raise "worker crashed"
      end)

    %{monitor_ref: monitor_ref, pid: worker} = socket.assigns.active_worker
    assert_receive {:DOWN, ^monitor_ref, :process, ^worker, reason}, 1_000

    assert {:halt, failed} =
             AgentLive.handle_worker_info(
               {:DOWN, monitor_ref, :process, worker, reason},
               socket
             )

    assert failed.assigns.active_request_id == nil
    assert failed.assigns.active_worker == nil
    assert failed.assigns.agent_view.status == :error
    assert failed.assigns.agent_view.error_text =~ "showcase_turn_worker_exited"
  end

  test "a stale worker exit does not change a newer request" do
    socket = worker_socket("showcase-current-worker")
    active_ref = make_ref()

    socket =
      Phoenix.Component.assign(socket,
        active_worker: %{
          monitor_ref: active_ref,
          pid: self(),
          request_id: "showcase-current-worker",
          view_module: View
        }
      )

    stale_message = {:DOWN, make_ref(), :process, self(), :old_worker_failed}
    assert {:halt, unchanged} = AgentLive.handle_worker_info(stale_message, socket)
    assert unchanged == socket
  end

  test "a successful worker result clears its monitor and running state" do
    request_id = "showcase-worker-success"
    result = result("Worker completed.")

    socket =
      worker_socket(request_id)
      |> AgentLive.start_turn_worker(View, request_id, "test:model", fn -> {:ok, result} end)

    %{monitor_ref: monitor_ref} = socket.assigns.active_worker

    assert_receive {:jidoka_turn_result, ^request_id, {:ok, ^result}, "test:model"} = message,
                   1_000

    assert {:halt, finished} = AgentLive.handle_worker_info(message, socket)
    assert finished.assigns.active_request_id == nil
    assert finished.assigns.active_worker == nil
    assert finished.assigns.agent_view.status == :idle
    assert finished.assigns.agent_view.outcome == {:ok, result}
    refute_receive {:DOWN, ^monitor_ref, :process, _worker, _reason}, 50
  end

  defp worker_socket(request_id) do
    {:ok, view} = View.initial(%{conversation_id: "worker-test"})
    view = View.before_turn(view, "Test the worker", request_id)

    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        active_request_id: request_id,
        active_worker: nil,
        agent_view: view,
        form: AgentLive.form("", "test:model")
      }
    }
  end

  defp result(content) do
    Jidoka.Turn.Result.new!(
      content: content,
      agent_state: Jidoka.Agent.State.new!(),
      journal: Jidoka.Effect.Journal.new!()
    )
  end
end
