defmodule Mix.Tasks.Jidoka.Examples.CheckTest do
  use ExUnit.Case, async: false

  test "documents verbose output without a quick mode" do
    Mix.shell(Mix.Shell.Process)
    Mix.Task.reenable("jidoka.examples.check")

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
    end)

    assert :ok == Mix.Task.run("jidoka.examples.check", ["--help"])
    assert_receive {:mix_shell, :info, [help]}
    assert help =~ "--verbose"
    refute help =~ "--quick"
  end
end
