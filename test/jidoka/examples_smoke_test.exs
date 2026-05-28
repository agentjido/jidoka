defmodule JidokaTest.ExamplesSmokeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup_all do
    Code.require_file("../../examples/registry.exs", __DIR__)
    :ok
  end

  test "registry exposes named examples in teaching order" do
    assert registry(:names) == [
             :first_agent,
             :ticket_classifier,
             :support_agent,
             :debug_agent,
             :workflow_agent,
             :delegation_agent,
             :knowledge_agent,
             :ash_agent
           ]
  end

  test "registered examples run provider-free" do
    for example <- registry(:all) do
      assert {:ok, result} = registry(:run, [example.name])
      assert result.example == example.name
      assert result.mode == :verify
    end
  end

  test "mix task lists examples" do
    Mix.Task.reenable("jidoka.example")

    output =
      capture_io(fn ->
        Mix.Tasks.Jidoka.Example.run(["--list"])
      end)

    assert output =~ "support_agent"
    assert output =~ "knowledge_agent"
  end

  defp registry(function, args \\ []), do: apply(Module.concat([JidokaExamples]), function, args)
end
