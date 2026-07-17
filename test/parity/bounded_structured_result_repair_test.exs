defmodule Jidoka.Parity.BoundedStructuredResultRepairTest do
  use Jidoka.ParityCase, parity: :bounded_structured_result_repair

  alias Jidoka.Effect
  alias Jidoka.Error.ExecutionError
  alias Jidoka.Event
  alias Jidoka.Schema
  alias Jidoka.Stream
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [event_index: 2, timeline: 1]

  defmodule ResultAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :bounded_structured_result_repair do
      model %{provider: :test, id: "scripted-model"}
      instructions "Return a typed answer and non-negative score."

      result schema:
               Zoi.object(%{
                 answer: Zoi.string(),
                 score: Zoi.integer() |> Zoi.gte(0)
               }),
             max_repairs: 1
    end
  end

  test "validates immediately, repairs once, and fails after the declared bound" do
    {:ok, valid_counter} = Elixir.Agent.start_link(fn -> 0 end)

    valid_llm = fn _intent, _journal, _context ->
      bump(valid_counter)

      {:ok,
       %{
         type: :final,
         content: "Ada is valid.",
         result: %{"answer" => "Ada", "score" => 10}
       }}
    end

    assert {:ok, %Turn.Result{} = valid_result} =
             ResultAgent.run_turn(
               Turn.Request.new!(input: "Return Ada.", request_id: "parity-structured-valid"),
               llm: valid_llm
             )

    assert valid_result.value == %{answer: "Ada", score: 10}
    assert calls(valid_counter) == 1
    assert Enum.count(valid_result.events, &(&1.event == :result_validated)) == 1
    refute Enum.any?(valid_result.events, &(&1.event == :result_repair_requested))

    {:ok, repair_counter} = Elixir.Agent.start_link(fn -> 0 end)

    repairing_llm = fn %Effect.Intent{payload: payload}, _journal, _context ->
      case bump(repair_counter) do
        1 ->
          {:ok,
           %{
             type: :final,
             content: "Ada might be valid.",
             result: %{"answer" => "Ada", "score" => "ten"}
           }}

        2 ->
          assert repair_prompt?(Schema.get_key(payload, :prompt))

          {:ok,
           %{
             type: :final,
             content: "Ada is repaired.",
             result: %{"answer" => "Ada", "score" => 10}
           }}
      end
    end

    assert {:ok, %Turn.Result{} = repaired_result} =
             ResultAgent.run_turn(
               Turn.Request.new!(input: "Repair Ada.", request_id: "parity-structured-repaired"),
               llm: repairing_llm
             )

    assert repaired_result.value == %{answer: "Ada", score: 10}
    assert calls(repair_counter) == 2

    assert [repair_event] =
             Enum.filter(repaired_result.events, &(&1.event == :result_repair_requested))

    assert Schema.get_key(repair_event.data, :repair_count) == 1
    assert Enum.count(repaired_result.events, &(&1.event == :result_validated)) == 1

    repaired_timeline = timeline(repaired_result.events)
    assert event_index(repaired_timeline, :result_repair_requested) < event_index(repaired_timeline, :result_validated)

    assert Enum.any?(repaired_result.agent_state.messages, fn message ->
             metadata = Schema.get_key(message, :metadata, %{})
             content = Schema.get_key(message, :content, "")

             Schema.get_key(metadata, :jidoka_result_repair) == true and
               Schema.get_key(metadata, :repair_count) == 1 and
               String.contains?(content, "score: invalid type: expected integer") and
               not String.contains?(content, "%Zoi.Error")
           end)

    {:ok, exhausted_counter} = Elixir.Agent.start_link(fn -> 0 end)

    always_invalid_llm = fn _intent, _journal, _context ->
      bump(exhausted_counter)

      {:ok,
       %{
         type: :final,
         content: "Ada remains invalid.",
         result: %{"answer" => "Ada", "score" => "still not an integer"}
       }}
    end

    exhausted_request =
      Turn.Request.new!(
        input: "Exhaust Ada repairs.",
        request_id: "parity-structured-exhausted"
      )

    assert {:error,
            %ExecutionError{
              phase: :result,
              details: %{
                reason: :invalid_result,
                repair_attempts: 1,
                max_repairs: 1
              }
            }} =
             ResultAgent.run_turn(exhausted_request,
               llm: always_invalid_llm,
               stream_to: self()
             )

    assert calls(exhausted_counter) == 2

    streamed_events =
      "parity-structured-exhausted"
      |> Stream.events(stream_event_timeout_ms: 25)
      |> Enum.to_list()

    assert Enum.count(streamed_events, &(&1.event == :result_repair_requested)) == 1

    assert %Event{event: :turn_failed, status: :failed, data: %{reason: failure_reason}} =
             List.last(streamed_events)

    assert String.contains?(failure_reason, "invalid_result")
    refute Enum.any?(streamed_events, &(&1.event == :result_validated))
  end

  defp repair_prompt?(prompt) do
    prompt
    |> Schema.get_key(:messages, [])
    |> Enum.any?(fn message ->
      metadata = Schema.get_key(message, :metadata, %{})

      Schema.get_key(metadata, :jidoka_result_repair) == true and
        Schema.get_key(metadata, :repair_count) == 1
    end)
  end

  defp bump(counter), do: Elixir.Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)
  defp calls(counter), do: Elixir.Agent.get(counter, & &1)
end
