defmodule JidokaExamples.GettingStartedTest do
  use ExUnit.Case, async: true

  alias JidokaExamples.GettingStarted.Scenario

  @moduletag example: :getting_started
  @moduletag scenario: :first_conversation
  @moduletag timeout: 5_000

  @tag :code_first_authoring
  @tag :local_inspection
  @tag :provider_model_abstraction
  @tag :provider_free_testing
  @tag :synchronous_execution
  test "keeps context across repeated public session chat calls" do
    assert {:ok, report} = Scenario.run(observer: self())

    assert report.agent_id == "getting_started"
    assert report.model == "openai:gpt-4o-mini"
    assert report.session_id == "getting-started-session"
    assert report.turn_count == 2

    assert report.inputs == [
             "Remember that my team is called Platform.",
             "What is my team called?"
           ]

    assert report.answers == [
             "I will remember that your team is called Platform.",
             "Your team is called Platform."
           ]

    assert report.messages == [
             %{role: :system, content: "Answer clearly and briefly."},
             %{role: :user, content: "Remember that my team is called Platform."}
           ]

    assert report.operations == []
    assert report.diagnostics == []

    assert_receive {:getting_started_model_called, first_prompt}
    assert_receive {:getting_started_model_called, second_prompt}

    assert Enum.map(second_prompt, &Map.get(&1, :content)) == [
             "Answer clearly and briefly.",
             "Remember that my team is called Platform.",
             "I will remember that your team is called Platform.",
             "What is my team called?"
           ]

    assert length(first_prompt) == 2
    refute_receive {:getting_started_model_called, _prompt}
  end
end
