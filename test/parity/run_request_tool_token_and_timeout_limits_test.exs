defmodule Jidoka.Parity.RunRequestToolTokenAndTimeoutLimitsTest do
  use Jidoka.ParityCase, parity: :run_request_tool_token_and_timeout_limits

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Error.ExecutionError
  alias Jidoka.Schema
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  test "input length stops an oversized request before the model runs" do
    spec =
      base_spec(
        controls: %{
          inputs: [
            %{control: Jidoka.Controls.MaxInputLength, metadata: %{max: 5}}
          ]
        }
      )

    llm = fn _intent, _journal, _context ->
      flunk("an oversized request must not call the model")
    end

    assert {:error,
            %ExecutionError{
              phase: :control,
              details: %{
                reason: :control_blocked,
                control: "max_input_length",
                boundary: :input,
                cause: {:input_too_long, 8, 5}
              }
            }} = Jidoka.turn(spec, "too long", llm: llm)
  end

  test "model turns and provider output tokens keep their declared bounds" do
    spec =
      base_spec(
        generation: %{params: %{max_tokens: 17}},
        controls: %{max_turns: 1},
        operations: [Operation.new!(name: "lookup")]
      )

    llm = fn %Effect.Intent{payload: payload}, _journal, _context ->
      assert Schema.get_key(payload.generation.params, :max_tokens) == 17
      {:ok, %{type: :operation, name: "lookup", arguments: %{}}}
    end

    operations = fn _intent, _journal, _context -> {:ok, %{found: true}} end

    assert {:error,
            %ExecutionError{
              phase: :turn,
              details: %{reason: :max_model_turns_exceeded, max_model_turns: 1}
            }} = Jidoka.turn(spec, "Look up", llm: llm, operations: operations)
  end

  test "turn and capability timeouts have distinct typed terminal reasons" do
    clock_counter = :counters.new(1, [])

    clock = fn ->
      :counters.add(clock_counter, 1, 1)
      if :counters.get(clock_counter, 1) == 1, do: 0, else: 11
    end

    timed_turn = base_spec(controls: %{timeout_ms: 10})
    never_called = fn _intent, _journal, _context -> flunk("expired turn called the model") end

    assert {:error,
            %ExecutionError{
              phase: :turn,
              details: %{
                reason: :turn_timeout_exceeded,
                timeout_ms: 10,
                elapsed_ms: 11
              }
            }} = Jidoka.turn(timed_turn, "Expire", llm: never_called, clock: clock)

    parent = self()

    slow_llm = fn _intent, _journal, _context ->
      send(parent, {:slow_model_started, self()})
      Process.sleep(5_000)
      {:ok, %{type: :final, content: "too late"}}
    end

    assert {:error,
            %ExecutionError{
              phase: :effect,
              details: %{
                reason: :capability_timeout,
                effect_kind: :llm,
                timeout_ms: 5
              }
            }} = Jidoka.turn(base_spec(), "Time out model", llm: slow_llm, capability_timeout_ms: 5)

    assert_receive {:slow_model_started, capability_pid}, 1_000
    refute Process.alive?(capability_pid)
  end

  test "parallel operation batches enforce the configured concurrency cap" do
    {:ok, concurrency} = Elixir.Agent.start_link(fn -> %{active: 0, max: 0} end)

    operations = fn %Effect.Intent{payload: payload}, _journal, _context ->
      Elixir.Agent.update(concurrency, fn state ->
        active = state.active + 1
        %{active: active, max: max(active, state.max)}
      end)

      Process.sleep(10)
      Elixir.Agent.update(concurrency, &%{&1 | active: &1.active - 1})
      {:ok, %{operation: payload.name}}
    end

    llm = fn _intent, %Effect.Journal{} = journal, _context ->
      if count_results(journal, :operation) == 0 do
        {:ok,
         %{
           type: :operations,
           operations: [
             %{name: "first", arguments: %{}},
             %{name: "second", arguments: %{}},
             %{name: "third", arguments: %{}}
           ]
         }}
      else
        {:ok, %{type: :final, content: "bounded"}}
      end
    end

    spec =
      base_spec(operations: Enum.map(["first", "second", "third"], &Operation.new!(name: &1)))

    assert {:ok, %Turn.Result{content: "bounded"}} =
             Jidoka.turn(spec, "Run tools",
               llm: llm,
               operations: operations,
               max_parallel_operations: 1
             )

    assert Elixir.Agent.get(concurrency, & &1.max) == 1
  end

  test "structured-result repair stops at its exact configured attempt bound" do
    calls = :counters.new(1, [])

    llm = fn _intent, _journal, _context ->
      :counters.add(calls, 1, 1)

      {:ok,
       %{
         type: :final,
         content: "invalid",
         result: %{"answer" => "Ada", "score" => "not-an-integer"}
       }}
    end

    spec =
      base_spec(
        result: %{
          schema: Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}),
          max_repairs: 1
        }
      )

    assert {:error,
            %ExecutionError{
              phase: :result,
              details: %{
                reason: :invalid_result,
                repair_attempts: 1,
                max_repairs: 1
              }
            }} = Jidoka.turn(spec, "Return data", llm: llm)

    assert :counters.get(calls, 1) == 2
  end

  defp base_spec(overrides \\ []) do
    defaults = [
      id: "parity_execution_limits_agent",
      instructions: "Stay within all declared execution budgets.",
      model: %{provider: :test, id: "scripted-model"}
    ]

    defaults
    |> Keyword.merge(overrides)
    |> Agent.Spec.new!()
  end
end
