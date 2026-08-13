defmodule Jidoka.Effect.OperationFailureTest do
  use ExUnit.Case, async: true

  alias Jidoka.CodingPack.Error, as: CodingError
  alias Jidoka.Effect.OperationFailure

  test "publishes the stable failure classes" do
    assert OperationFailure.kinds() == [
             :recoverable,
             :transport,
             :policy,
             :review,
             :reconciliation,
             :cancelled,
             :runtime
           ]
  end

  test "classifies recoverable coding conflicts and builds a safe observation" do
    failure =
      OperationFailure.classify(
        CodingError.new(:coding_write_conflict, %{expected: "old", actual: "new", api_key: "secret"})
      )

    assert failure.kind == :recoverable
    assert failure.code == :coding_write_conflict
    assert failure.details["api_key"] == nil

    assert %{
             "ok" => false,
             "error" => %{
               "kind" => "recoverable",
               "code" => "coding_write_conflict",
               "details" => details
             }
           } = OperationFailure.to_observation(failure)

    assert details["expected"] == "old"
  end

  test "keeps terminal failure classes separate from recoverable tool results" do
    cases = [
      {OperationFailure.classify(:timeout), :transport},
      {OperationFailure.classify(:cancelled), :cancelled},
      {OperationFailure.classify({:policy_denied, "rule", :blocked}), :policy},
      {OperationFailure.classify({:approval_denied, %{}}), :review},
      {OperationFailure.classify({:effect_reconciliation_required, :intent}), :reconciliation},
      {OperationFailure.classify(RuntimeError.exception("boom")), :runtime}
    ]

    for {failure, kind} <- cases do
      assert failure.kind == kind
      refute OperationFailure.model_visible?(failure)
    end
  end

  test "explicit wrappers override built-in classification" do
    failure = OperationFailure.recoverable(:timeout, code: :stale_cache)

    assert OperationFailure.classify(failure) == failure
    assert failure.kind == :recoverable
    assert failure.code == :stale_cache
  end

  test "omits non-portable failure details from model observations" do
    failure = OperationFailure.recoverable(:stale_cache, details: %{callback: fn -> :secret end})

    assert failure.details == %{"reason" => "non-portable failure details omitted"}
    refute inspect(OperationFailure.to_observation(failure)) =~ "secret"
  end
end
