defmodule Jidoka.MultiTurnIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Controls
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.IntegrationSupport.AccountAgent
  alias Jidoka.IntegrationSupport.ApprovalControl
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Runtime.LocalOperations
  alias Jidoka.Turn

  test "caller-managed agent state carries tool observations across separate turns" do
    test_pid = self()

    spec =
      Agent.Spec.new!(
        id: "order_session_agent",
        instructions: "Use order tools and preserve enough context for follow-up turns.",
        operations: [
          Operation.new!(
            name: "lookup_order",
            description: "Looks up an order by id.",
            idempotency: :idempotent
          ),
          Operation.new!(
            name: "refund_order",
            description: "Starts a refund for an order.",
            idempotency: :unsafe_once
          )
        ],
        controls:
          Controls.new!(
            operations: [
              %{control: ApprovalControl, match: %{name: "refund_order"}}
            ]
          ),
        runtime_defaults: %{max_model_turns: 4}
      )

    operations =
      LocalOperations.operations(%{
        lookup_order: fn intent, _journal ->
          arguments = Jidoka.Schema.get_key(intent.payload, :arguments)

          send(test_pid, {:operation_called, "lookup_order", arguments, intent.idempotency})

          {:ok,
           %{
             "order_id" => arguments["order_id"],
             "status" => "shipped",
             "carrier" => "UPS"
           }}
        end,
        refund_order: fn intent, _journal ->
          arguments = Jidoka.Schema.get_key(intent.payload, :arguments)

          send(test_pid, {:operation_called, "refund_order", arguments, intent.idempotency})

          {:ok,
           %{
             "order_id" => arguments["order_id"],
             "refund_id" => "refund_001",
             "status" => "queued"
           }}
        end
      })

    first_turn_llm = fn intent, %Effect.Journal{} = journal ->
      case count_results(journal, :llm) do
        0 ->
          assert prompt_messages(intent) |> Enum.all?(&(Map.get(&1, :role) != :assistant))

          {:ok,
           %{
             type: :operation,
             name: "lookup_order",
             arguments: %{"order_id" => "order_123"}
           }}

        1 ->
          assert journal_has_operation_result?(journal, "lookup_order")
          {:ok, %{type: :final, content: "Order order_123 has shipped via UPS."}}
      end
    end

    assert {:ok, %Turn.Result{} = first_result} =
             Jidoka.run_turn(spec, Turn.Request.new!(input: "Check order order_123"),
               llm: first_turn_llm,
               operations: operations
             )

    assert first_result.content == "Order order_123 has shipped via UPS."

    assert [%Effect.OperationResult{operation: "lookup_order"}] =
             first_result.agent_state.operation_results

    assert length(first_result.agent_state.messages) == 2
    assert_received {:operation_called, "lookup_order", %{"order_id" => "order_123"}, :idempotent}

    second_turn_llm = fn intent, %Effect.Journal{} = journal ->
      case count_results(journal, :llm) do
        0 ->
          messages = prompt_messages(intent)

          assert message_with_content?(messages, "Order order_123 has shipped via UPS.")
          assert tool_observation?(messages, "lookup_order", "order_123")

          {:ok,
           %{
             type: :operation,
             name: "refund_order",
             arguments: %{"order_id" => "order_123", "reason" => "customer_request"}
           }}

        1 ->
          assert journal_has_operation_result?(journal, "refund_order")
          {:ok, %{type: :final, content: "Refund refund_001 is queued for order_123."}}
      end
    end

    assert {:ok, %Turn.Result{} = second_result} =
             Jidoka.run_turn(
               spec,
               Turn.Request.new!(
                 input: "Refund it for the customer.",
                 request_id: "turn-2",
                 agent_state: first_result.agent_state
               ),
               llm: second_turn_llm,
               operations: operations
             )

    assert second_result.content == "Refund refund_001 is queued for order_123."

    assert operation_names(second_result.agent_state.operation_results) == [
             "lookup_order",
             "refund_order"
           ]

    assert length(second_result.agent_state.messages) == 4

    assert_received {:operation_called, "refund_order",
                     %{"order_id" => "order_123", "reason" => "customer_request"}, :unsafe_once}
  end

  test "durable hibernate/resume can drive a multi-effect turn through portable snapshots" do
    test_pid = self()

    spec =
      Agent.Spec.new!(
        id: "durable_weather_agent",
        instructions: "Geocode a place, fetch weather, then answer.",
        operations: [
          Operation.new!(
            name: "geocode",
            description: "Converts a place name into coordinates.",
            idempotency: :idempotent
          ),
          Operation.new!(
            name: "weather",
            description: "Looks up weather by coordinates.",
            idempotency: :idempotent
          )
        ],
        runtime_defaults: %{max_model_turns: 6}
      )

    llm = fn intent, %Effect.Journal{} = journal ->
      loop_index = Jidoka.Schema.get_key(intent.payload, :loop_index)
      send(test_pid, {:llm_called, loop_index, intent.idempotency_key})

      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "geocode",
             arguments: %{"place" => "Millennium Park"}
           }}

        1 ->
          assert prompt_messages(intent) |> tool_observation?("geocode", "Millennium Park")

          {:ok,
           %{
             type: :operation,
             name: "weather",
             arguments: %{"lat" => 41.8827, "lon" => -87.6226}
           }}

        2 ->
          assert prompt_messages(intent) |> tool_observation?("weather", "clear")

          {:ok,
           %{
             type: :final,
             content: "Millennium Park is clear and 72F."
           }}
      end
    end

    operations =
      LocalOperations.operations(%{
        geocode: fn intent, _journal ->
          arguments = Jidoka.Schema.get_key(intent.payload, :arguments)
          send(test_pid, {:operation_called, "geocode", intent.idempotency_key})

          {:ok,
           %{
             "place" => arguments["place"],
             "lat" => 41.8827,
             "lon" => -87.6226
           }}
        end,
        weather: fn intent, _journal ->
          arguments = Jidoka.Schema.get_key(intent.payload, :arguments)
          send(test_pid, {:operation_called, "weather", intent.idempotency_key})

          {:ok,
           %{
             "lat" => arguments["lat"],
             "lon" => arguments["lon"],
             "condition" => "clear",
             "temperature_f" => 72
           }}
        end
      })

    first_step =
      Jidoka.run_turn(spec, Turn.Request.new!(input: "Weather near Millennium Park"),
        llm: llm,
        operations: operations,
        checkpoint: :after_each_phase
      )

    assert {:ok, result, cursors} =
             drain_snapshots(first_step,
               llm: llm,
               operations: operations,
               checkpoint: :after_each_phase
             )

    assert result.content == "Millennium Park is clear and 72F."

    assert operation_names(result.agent_state.operation_results) == [
             "geocode",
             "weather"
           ]

    assert Enum.map(cursors, & &1.phase) == [
             :after_prompt,
             :before_effect,
             :after_prompt,
             :before_effect,
             :after_prompt
           ]

    assert Enum.map(cursors, & &1.loop_index) == [0, 0, 1, 1, 2]

    assert_receive {:operation_called, "geocode", geocode_key}
    assert_receive {:operation_called, "weather", weather_key}
    refute geocode_key == weather_key
    refute_received {:operation_called, _name, _key}

    llm_calls = collect_messages(:llm_called, [])
    assert Enum.map(llm_calls, fn {_tag, loop_index, _key} -> loop_index end) == [0, 1, 2]
  end

  test "Jido.AgentServer keeps Jidoka agent state between process-hosted turns" do
    id = "multi_turn_server_#{System.unique_integer([:positive])}"
    test_pid = self()

    on_exit(fn -> Jidoka.stop_agent(id) end)

    first_turn_llm = fn _intent, %Effect.Journal{} = journal ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "account_lookup",
             arguments: %{"account_id" => "acct_123"}
           }}

        1 ->
          {:ok, %{type: :final, content: "Account acct_123 is on the Pro plan."}}
      end
    end

    assert {:ok, pid} = AccountAgent.start(id: id)

    assert {:ok, %Turn.Result{content: "Account acct_123 is on the Pro plan."}} =
             Jidoka.run_turn(pid, "Check acct_123",
               llm: first_turn_llm,
               operation_context: %{test_pid: test_pid}
             )

    assert_receive {:account_lookup_called, "acct_123"}

    second_turn_llm = fn intent, %Effect.Journal{} = journal ->
      assert count_results(journal, :llm) == 0

      messages = prompt_messages(intent)
      assert message_with_content?(messages, "Account acct_123 is on the Pro plan.")
      assert tool_observation?(messages, "account_lookup", "acct_123")

      {:ok, %{type: :final, content: "Still Pro: acct_123 has 8 seats."}}
    end

    assert {:ok, "Still Pro: acct_123 has 8 seats."} =
             Jidoka.chat(id, "Remind me what plan that account has.", llm: second_turn_llm)

    assert {:ok, %{status: :completed, result: "Still Pro: acct_123 has 8 seats."}} =
             Jidoka.await_agent(pid, timeout: 100)
  end

  defp drain_snapshots(result, opts, cursors \\ [], remaining \\ 10)

  defp drain_snapshots({:ok, %Turn.Result{} = result}, _opts, cursors, _remaining),
    do: {:ok, result, cursors}

  defp drain_snapshots({:hibernate, %AgentSnapshot{} = snapshot}, opts, cursors, remaining)
       when remaining > 0 do
    serialized_snapshot = AgentSnapshot.serialize!(snapshot)

    serialized_snapshot
    |> Jidoka.resume(opts)
    |> drain_snapshots(opts, cursors ++ [snapshot.cursor], remaining - 1)
  end

  defp drain_snapshots({:error, reason}, _opts, _cursors, _remaining), do: {:error, reason}

  defp drain_snapshots({:hibernate, %AgentSnapshot{}}, _opts, _cursors, 0),
    do: flunk("snapshot drain exceeded the maximum number of resume steps")

  defp count_results(%Effect.Journal{results: results}, kind) do
    results
    |> Map.values()
    |> Enum.count(&(&1.kind == kind))
  end

  defp prompt_messages(%Effect.Intent{payload: payload}) do
    payload
    |> Jidoka.Schema.get_key(:prompt)
    |> Jidoka.Schema.get_key(:messages, [])
  end

  defp message_with_content?(messages, content) do
    Enum.any?(messages, &(Map.get(&1, :content) == content || Map.get(&1, "content") == content))
  end

  defp operation_names(operation_results) do
    Enum.map(operation_results, fn %Effect.OperationResult{operation: operation} -> operation end)
  end

  defp tool_observation?(messages, operation, expected_fragment) do
    Enum.any?(messages, fn message ->
      observed_operation = Map.get(message, :operation) || Map.get(message, "operation")
      output = Map.get(message, :output) || Map.get(message, "output") || %{}

      observed_operation == operation and output_contains?(output, expected_fragment)
    end)
  end

  defp output_contains?(output, expected_fragment) when is_binary(expected_fragment) do
    output
    |> inspect()
    |> String.contains?(expected_fragment)
  end

  defp journal_has_operation_result?(
         %Effect.Journal{intents: intents, results: results},
         operation
       ) do
    results
    |> Enum.any?(fn
      {intent_id, %Effect.Result{kind: :operation, status: :ok}} ->
        intent = Map.fetch!(intents, intent_id)
        Jidoka.Schema.get_key(intent.payload, :name) == operation

      _result ->
        false
    end)
  end

  defp collect_messages(tag, acc) do
    receive do
      {^tag, _loop_index, _key} = message -> collect_messages(tag, acc ++ [message])
    after
      0 -> acc
    end
  end
end
