defmodule Jidoka.Runtime.SignalsTest do
  use ExUnit.Case, async: true

  alias Jidoka.Runtime.Signals

  test "builds turn run signals for AgentServer routing" do
    signal =
      Signals.turn_run("hello",
        request_id: "request-1",
        context: %{tenant: "acme"},
        metadata: %{trace_id: "trace-1"},
        runtime_opts: [checkpoint: :none]
      )

    assert signal.type == Signals.turn_run_type()
    assert signal.source == "/jidoka"
    assert signal.data.input == "hello"
    assert signal.data.request_id == "request-1"
    assert signal.data.context == %{tenant: "acme"}
    assert signal.data.metadata == %{trace_id: "trace-1"}
    assert signal.data.runtime_opts == [checkpoint: :none]
  end
end
