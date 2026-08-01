defmodule Mix.Tasks.Jidoka.ExampleTest do
  use ExUnit.Case, async: false

  setup do
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
    end)

    :ok
  end

  test "prints help when no example is selected" do
    run_task([])

    assert_receive {:mix_shell, :info, [help]}
    assert help =~ "mix jidoka.example --list"
    assert help =~ "--json"
  end

  test "lists the example catalog as text and JSON" do
    run_task(["--list"])

    assert_receive {:mix_shell, :info, ["Available Jidoka examples:\n"]}
    assert_receive {:mix_shell, :info, [durable_refund_text]}
    assert_receive {:mix_shell, :info, [support_text]}
    assert_receive {:mix_shell, :info, [warranty_text]}
    assert durable_refund_text =~ "durable_refund"
    assert support_text =~ "support_agent"
    assert warranty_text =~ "warranty_claim"

    run_task(["--list", "--json"])

    assert_receive {:mix_shell, :info, [encoded]}

    assert [
             %{"name" => "durable_refund"} = durable_refund,
             %{"name" => "support_agent"} = support_agent,
             %{"name" => "warranty_claim"} = warranty_claim
           ] = Jason.decode!(encoded)

    assert "crash_recovery" in durable_refund["capabilities"]
    assert is_list(support_agent["capabilities"])
    assert "multimodal_content" in warranty_claim["capabilities"]
  end

  test "rejects invalid options and extra example names" do
    assert_raise Mix.Error, ~r/Unknown jidoka.example options/, fn ->
      run_task(["--unknown"])
    end

    assert_raise Mix.Error, ~r/Expected one example name/, fn ->
      run_task(["support_agent", "another_agent"])
    end
  end

  defp run_task(args) do
    Mix.Task.reenable("jidoka.example")
    assert :ok == Mix.Task.run("jidoka.example", args)
  end
end
