defmodule JidokaCLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Jidoka.TestAttemptExecutionAdapters.PromptSuccess

  test "help output lists the available commands" do
    output =
      capture_io(fn ->
        assert Jidoka.CLI.run([]) == 0
      end)

    assert output =~ "jidoka eval-mvp"
    assert output =~ "jidoka chat"
    assert output =~ "jidoka prompt"
    assert output =~ "jidoka version"
  end

  test "version prints the current application version" do
    output =
      capture_io(fn ->
        assert Jidoka.CLI.run(["version"]) == 0
      end)

    assert String.trim(output) == to_string(Application.spec(:jidoka, :vsn))
  end

  test "eval-mvp runs the evaluation corpus" do
    output =
      capture_io(fn ->
        assert Jidoka.CLI.run(["eval-mvp"]) == 0
      end)

    assert output =~ "scenario=passing_task"
    assert output =~ "scenario=retryable_verifier_failure"
    assert output =~ "scenario=resume_oriented"
  end

  test "prompt runs through the terminal workflow and prints the response" do
    previous_adapter = Application.get_env(:jidoka, :prompt_execution_adapter)
    Application.put_env(:jidoka, :prompt_execution_adapter, PromptSuccess)

    on_exit(fn ->
      if is_nil(previous_adapter) do
        Application.delete_env(:jidoka, :prompt_execution_adapter)
      else
        Application.put_env(:jidoka, :prompt_execution_adapter, previous_adapter)
      end
    end)

    output =
      capture_io(fn ->
        assert Jidoka.CLI.run(["prompt", "inspect", "the", "repo"]) == 0
      end)

    assert output =~ "session="
    assert output =~ "event=run_submitted"
    assert output =~ "label=runtime_ready"
    assert output =~ "approval=auto"
    assert output =~ "status=completed"
    assert output =~ "stub response for: inspect the repo"
  end

  test "prompt without text returns an error" do
    output =
      capture_io(:stderr, "   \n", fn ->
        assert Jidoka.CLI.run(["prompt"]) == 1
      end)

    assert output =~ "prompt text required"
  end

  test "unknown command prints an error and returns non-zero" do
    output =
      capture_io(:stderr, fn ->
        assert Jidoka.CLI.run(["wat"]) == 1
      end)

    assert output =~ "unknown command: wat"
    assert output =~ "jidoka eval-mvp"
    assert output =~ "jidoka prompt"
  end

  test "chat handles slash commands without requiring model configuration" do
    output =
      capture_io("/help\n/status\n/model\n/quit\n", fn ->
        assert Jidoka.CLI.run(["chat"]) == 0
      end)

    assert output =~ "jidoka chat"
    assert output =~ "/status"
    assert output =~ "turns=0"
    assert output =~ "model="
  end
end
