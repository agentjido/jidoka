defmodule Jidoka.DocumentedExamplesIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Effect
  alias Jidoka.IntegrationSupport.AccountAgent
  alias Jidoka.IntegrationSupport.InputControlledLookupAgent
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  test "getting started one-tool loop remains executable" do
    test_pid = self()

    llm = fn _intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "account_lookup",
             arguments: %{"account_id" => "acct_123"}
           }}

        1 ->
          {:ok, %{type: :final, content: "Account acct_123 is on Pro."}}
      end
    end

    request =
      Turn.Request.new!(
        input: "Check acct_123",
        context: %{test_pid: test_pid}
      )

    assert {:ok, %{content: "Account acct_123 is on Pro."}} =
             AccountAgent.run_turn(request,
               llm: llm,
               operation_context: %{test_pid: test_pid}
             )

    assert_receive {:account_lookup_called, "acct_123"}
  end

  test "controls guide input-control shape remains executable" do
    test_pid = self()
    llm = fn _intent, _journal, _ctx -> {:ok, %{type: :final, content: "allowed"}} end

    assert {:ok, %{content: "allowed"}} =
             InputControlledLookupAgent.run_turn(
               Turn.Request.new!(
                 input: "allowed input",
                 context: %{test_pid: test_pid}
               ),
               llm: llm
             )

    assert_receive {:input_control_called, "allowed input"}

    assert {:error, %Jidoka.Error.ExecutionError{details: %{reason: :control_blocked}}} =
             InputControlledLookupAgent.run_turn("blocked input", llm: llm)
  end
end
