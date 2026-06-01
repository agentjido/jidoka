defmodule Jidoka.EvalTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Eval
  alias Jidoka.Runtime.LocalOperations

  import Jidoka.TestSupport, only: [count_results: 2]

  test "run_case evaluates content and operation assertions" do
    spec =
      Agent.Spec.new!(
        id: "eval_agent",
        instructions: "Use lookup_account when account data is requested.",
        model: %{provider: :test, id: "model"},
        operations: [
          Operation.new!(
            name: "lookup_account",
            description: "Looks up an account.",
            idempotency: :idempotent
          )
        ],
        runtime_defaults: %{max_model_turns: 4}
      )

    llm = fn _intent, %Effect.Journal{} = journal ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "lookup_account",
             arguments: %{"account_id" => "acct_123"}
           }}

        1 ->
          {:ok, %{type: :final, content: "Account acct_123 is active."}}
      end
    end

    operations =
      LocalOperations.operations(%{
        lookup_account: fn %{"account_id" => account_id} ->
          %{account_id: account_id, status: "active"}
        end
      })

    assert {:ok,
            %Eval.Run{
              status: :passed,
              observations: %{operation_calls: ["lookup_account"]},
              assertions: assertions
            } = run} =
             Eval.run_case(
               [
                 id: "eval_lookup_account",
                 agent: spec,
                 input: "Check acct_123",
                 assertions: %{
                   contains: ["acct_123", "active"],
                   operation_called: :lookup_account
                 }
               ],
               llm: llm,
               operations: operations
             )

    assert Enum.all?(assertions, &(&1.status == :passed))
    assert %{kind: :eval_run, status: :passed, assertion_count: 3} = Jidoka.inspect(run)
  end

  test "run_case returns a failed run for assertion mismatches" do
    spec =
      Agent.Spec.new!(
        id: "eval_failure_agent",
        instructions: "Answer directly.",
        model: %{provider: :test, id: "model"}
      )

    llm = fn _intent, _journal -> {:ok, %{type: :final, content: "hello"}} end

    assert {:ok, %Eval.Run{status: :failed, assertions: [assertion]}} =
             Eval.run_case(
               [
                 id: "eval_failure",
                 agent: spec,
                 input: "Say hello",
                 assertions: %{equals: "goodbye"}
               ],
               llm: llm
             )

    assert %{name: :equals, status: :failed, expected: "goodbye", actual: "hello"} = assertion
  end

  test "eval case constructors normalize requests and generated ids" do
    spec =
      Agent.Spec.new!(
        id: "eval_case_agent",
        instructions: "Answer directly.",
        model: %{provider: :test, id: "model"}
      )

    assert {:ok,
            %Eval.Case{
              id: "eval_fixed",
              request: %{request_id: "turn_fixed", input: "Hello"},
              assertions: %{}
            }} =
             Eval.Case.new(
               [agent: spec, input: "Hello"],
               id_generator: fn
                 "eval" -> "eval_fixed"
                 "turn" -> "turn_fixed"
               end
             )

    assert {:error, :missing_eval_agent} = Eval.Case.new(id: "missing", input: "Hello")
    assert {:error, {:invalid_eval_case_id, ""}} = Eval.Case.new(id: "", agent: spec)

    assert {:error, {:invalid_generated_id, "eval", ""}} =
             Eval.Case.new([agent: spec, input: "Hello"], id_generator: fn "eval" -> "" end)

    assert_raise ArgumentError, ~r/invalid eval case/, fn ->
      Eval.Case.new!(id: "", agent: spec)
    end

    assert Eval.Run.statuses() == [:passed, :failed, :error]

    assert {:error, _reason} = Eval.Run.new(case_id: "bad", status: :unknown)
    assert_raise ArgumentError, ~r/invalid eval run/, fn -> Eval.Run.new!(case_id: "bad") end
  end

  test "run_case records hibernation as an eval error run" do
    spec =
      Agent.Spec.new!(
        id: "eval_hibernate_agent",
        instructions: "Answer directly.",
        model: %{provider: :test, id: "model"}
      )

    llm = fn _intent, _journal -> {:ok, %{type: :final, content: "hello"}} end

    assert {:ok, %Eval.Run{status: :error, error: %{reason: :hibernated}}} =
             Eval.run_case(
               [
                 id: "eval_hibernate",
                 agent: spec,
                 input: "Say hello"
               ],
               llm: llm,
               checkpoint: :after_prompt
             )
  end
end
