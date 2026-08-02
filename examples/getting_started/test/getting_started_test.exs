defmodule JidokaExamples.GettingStartedTest do
  use ExUnit.Case, async: true

  alias JidokaExamples.GettingStarted.Scenario

  @moduletag example: :getting_started
  @moduletag scenario: :first_chat
  @moduletag timeout: 5_000

  @tag :code_first_authoring
  @tag :local_inspection
  @tag :provider_model_abstraction
  @tag :provider_free_testing
  @tag :synchronous_execution
  test "answers one text request through the public chat path" do
    assert {:ok, report} = Scenario.run(observer: self())

    assert report.agent_id == "getting_started"
    assert report.model == "openai:gpt-4o-mini"
    assert report.input == "What can you help me with?"

    assert report.messages == [
             %{role: :system, content: "Answer clearly and briefly."},
             %{role: :user, content: "What can you help me with?"}
           ]

    assert report.operations == []
    assert report.diagnostics == []
    assert report.answer == "I can explain Jidoka agents and help you build one."
    assert_receive :getting_started_model_called
    refute_receive :getting_started_model_called
  end
end
