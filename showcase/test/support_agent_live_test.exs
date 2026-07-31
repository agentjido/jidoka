defmodule JidokaShowcaseWeb.SupportAgentLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias JidokaExamples.SupportAgent.Agent
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
end
