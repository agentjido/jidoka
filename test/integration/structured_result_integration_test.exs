defmodule Jidoka.StructuredResultIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [event_index: 2, final_llm: 1, final_llm: 2, timeline: 1]

  defmodule CaptureOutputControl do
    use Jidoka.Control, name: "capture_structured_result"

    @impl true
    def call(%{request_metadata: %{test_pid: test_pid}, result_value: value}) do
      send(test_pid, {:output_control_value, value})
      :cont
    end

    def call(_context), do: :cont
  end

  test "valid structured final output produces app-facing result value" do
    assert {:ok, %Turn.Result{} = result} =
             Jidoka.turn(
               spec(),
               request(),
               llm: final_llm("Ada is ready.", result: %{"answer" => "Ada", "score" => 10})
             )

    assert result.content == "Ada is ready."
    assert result.value == %{answer: "Ada", score: 10}
    assert_receive {:output_control_value, %{answer: "Ada", score: 10}}

    timeline = timeline(result.events)
    result_validated_index = event_index(timeline, :result_validated)
    result_control_index = event_index(timeline, :control_allowed)

    assert result_validated_index < result_control_index
  end

  test "structured final output may be returned as JSON content" do
    content = Jason.encode!(%{"answer" => "Ada", "score" => 10})

    assert {:ok, %Turn.Result{} = result} =
             Jidoka.turn(
               spec(),
               request(),
               llm: final_llm(content)
             )

    assert result.content == content
    assert result.value == %{answer: "Ada", score: 10}
  end

  test "invalid structured final output repairs within the configured bound" do
    assert {:ok, %Turn.Result{} = result} =
             Jidoka.turn(spec(max_repairs: 1), request(), llm: repairing_llm())

    assert result.value == %{answer: "Ada", score: 10}

    timeline = timeline(result.events)
    assert Enum.any?(timeline, &match?(%{event: :result_repair_requested}, &1))
    assert Enum.any?(timeline, &match?(%{event: :result_validated}, &1))

    assert Enum.any?(result.agent_state.messages, fn
             %{metadata: %{"jidoka_result_repair" => true}, content: content} ->
               content =~ "score: invalid type: expected integer" and
                 not String.contains?(content, "%Zoi.Error")

             _message ->
               false
           end)
  end

  test "invalid structured final output fails after repairs are exhausted" do
    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :result,
              details: %{
                reason: :invalid_result,
                repair_attempts: 0,
                max_repairs: 0
              }
            }} =
             Jidoka.turn(spec(max_repairs: 0), request(),
               llm: fn _intent, _journal ->
                 {:ok,
                  %{
                    type: :final,
                    content: "Broken.",
                    result: %{"answer" => "Ada", "score" => "not an integer"}
                  }}
               end
             )
  end

  defp spec(opts \\ []) do
    Agent.Spec.new!(
      id: "structured_result_agent",
      instructions: "Return a structured result.",
      model: %{provider: :test, id: "model"},
      result: [
        schema:
          Zoi.object(%{
            answer: Zoi.string(),
            score: Zoi.integer() |> Zoi.gte(0)
          }),
        max_repairs: Keyword.get(opts, :max_repairs, 1)
      ],
      controls: %{
        outputs: [%{control: CaptureOutputControl}]
      }
    )
  end

  defp request do
    Turn.Request.new!(
      input: "Return Ada.",
      metadata: %{test_pid: self()}
    )
  end

  defp repairing_llm do
    fn _intent, %Effect.Journal{} = journal ->
      case map_size(journal.results) do
        0 ->
          {:ok,
           %{
             type: :final,
             content: "Ada maybe.",
             result: %{"answer" => "Ada", "score" => "not an integer"}
           }}

        _after_repair ->
          {:ok,
           %{
             type: :final,
             content: "Ada is repaired.",
             result: %{"answer" => "Ada", "score" => 10}
           }}
      end
    end
  end
end
