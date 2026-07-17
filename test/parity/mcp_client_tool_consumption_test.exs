defmodule Jidoka.Parity.MCPClientToolConsumptionTest do
  use Jidoka.ParityCase, parity: :mcp_client_tool_consumption

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Error.ExecutionError
  alias Jidoka.Event
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.MCP
  alias Jidoka.Schema
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  @local_operation "mcp_lookup_customer_record"
  @remote_tool "lookup_customer_record"

  defmodule MCPRecorder do
    @moduledoc false

    def record(call), do: Elixir.Agent.update(__MODULE__, &[call | &1])
    def calls, do: Elixir.Agent.get(__MODULE__, &Enum.reverse/1)
  end

  defmodule FakeMCPClient do
    @moduledoc false

    alias Jidoka.Parity.MCPClientToolConsumptionTest.MCPRecorder

    def remote_schema do
      %{
        "type" => "object",
        "properties" => %{
          "account_id" => %{"type" => "string"},
          "include_history" => %{"type" => "boolean"}
        },
        "required" => ["account_id"]
      }
    end

    def list_tools(endpoint, _opts)
        when endpoint in [:parity_mcp_success, :parity_mcp_failure] do
      {:ok,
       %{
         data: %{
           "tools" => [
             %{
               "name" => "lookup_customer_record",
               "description" => "Looks up one customer record from the fake MCP server.",
               "inputSchema" => remote_schema()
             }
           ]
         }
       }}
    end

    def call_tool(:parity_mcp_success, remote_name, arguments, opts) do
      MCPRecorder.record({:call_tool, :parity_mcp_success, remote_name, arguments, opts})

      {:ok,
       %{
         data: %{
           "account_id" => arguments["account_id"],
           "history_included" => arguments["include_history"],
           "tier" => "gold"
         }
       }}
    end

    def call_tool(:parity_mcp_failure, remote_name, arguments, opts) do
      MCPRecorder.record({:call_tool, :parity_mcp_failure, remote_name, arguments, opts})
      {:error, :fake_remote_failure}
    end
  end

  test "discovers and consumes one MCP client tool with typed failure evidence" do
    {:ok, recorder} = Elixir.Agent.start_link(fn -> [] end, name: MCPRecorder)
    {:ok, success_model_calls} = Elixir.Agent.start_link(fn -> 0 end)
    {:ok, failure_model_calls} = Elixir.Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      Enum.each([recorder, success_model_calls, failure_model_calls], fn pid ->
        if Process.alive?(pid), do: Elixir.Agent.stop(pid)
      end)
    end)

    test_pid = self()
    remote_schema = FakeMCPClient.remote_schema()
    model_arguments = %{"account_id" => "acct_123", "include_history" => true}

    assert {:ok, %{operations: [operation], capability: success_capability}} =
             :parity_mcp_success
             |> source()
             |> Source.compile(discover_mcp?: true)

    assert %Operation{name: @local_operation, idempotency: :idempotent} = operation
    assert Operation.kind(operation) == :mcp
    assert operation.metadata["source"] == "mcp"
    assert operation.metadata["endpoint"] == "parity_mcp_success"
    assert operation.metadata["remote_tool"] == @remote_tool
    assert operation.metadata["prefix"] == "mcp_"
    assert operation.metadata["parameters_schema"] == remote_schema

    success_spec = spec("mcp_client_success", [operation])

    success_request =
      Turn.Request.new!(
        input: "Look up account acct_123 and include its history.",
        request_id: "parity_mcp_success_request"
      )

    assert {:ok, %Turn.Result{content: "Customer acct_123 is on the gold tier."} = result} =
             Jidoka.turn(success_spec, success_request,
               llm: success_llm(success_model_calls, test_pid, model_arguments),
               operations: success_capability
             )

    assert Elixir.Agent.get(success_model_calls, & &1) == 2

    assert_receive {:success_model_prompt, 1, first_prompt}
    assert_receive {:success_model_prompt, 2, second_prompt}

    assert [prompt_operation] = value(first_prompt, :operations)
    assert prompt_operation.name == @local_operation
    assert prompt_operation.description == "Looks up one customer record from the fake MCP server."
    assert prompt_operation.idempotency == :idempotent
    assert prompt_operation.parameters_schema == remote_schema

    assert [] == tool_messages(first_prompt, @local_operation)

    expected_output = %{
      endpoint: "parity_mcp_success",
      tool: @remote_tool,
      result: %{
        "account_id" => "acct_123",
        "history_included" => true,
        "tier" => "gold"
      }
    }

    assert [tool_message] = tool_messages(second_prompt, @local_operation)
    assert value(tool_message, :output) == expected_output

    assert [operation_result] = result.agent_state.operation_results
    assert operation_result.operation == @local_operation
    assert operation_result.arguments == model_arguments
    assert operation_result.output == expected_output

    assert [operation_intent] =
             result.journal.intents
             |> Map.values()
             |> Enum.filter(&match?(%Effect.Intent{kind: :operation}, &1))

    assert operation_intent.payload.name == @local_operation
    assert operation_intent.payload.arguments == model_arguments
    assert count_results(result.journal, :operation) == 1

    assert %Effect.Result{kind: :operation, status: :ok, output: ^expected_output} =
             Map.fetch!(result.journal.results, operation_intent.id)

    assert MCPRecorder.calls() == [
             {:call_tool, :parity_mcp_success, @remote_tool, model_arguments, []}
           ]

    assert {:ok, %{operations: [failure_operation], capability: failure_capability}} =
             :parity_mcp_failure
             |> source()
             |> Source.compile(discover_mcp?: true)

    assert failure_operation.name == @local_operation
    assert failure_operation.metadata["remote_tool"] == @remote_tool
    assert failure_operation.metadata["parameters_schema"] == remote_schema

    failure_spec = spec("mcp_client_failure", [failure_operation])

    failure_request =
      Turn.Request.new!(
        input: "Look up account acct_500.",
        request_id: "parity_mcp_failure_request"
      )

    assert {:error,
            %ExecutionError{
              phase: :effect,
              details: %{cause: :fake_remote_failure, effect_kind: :operation}
            }} =
             Jidoka.turn(failure_spec, failure_request,
               llm: failure_llm(failure_model_calls, test_pid, model_arguments),
               operations: failure_capability,
               stream_to: self()
             )

    assert Elixir.Agent.get(failure_model_calls, & &1) == 1
    assert_receive {:failure_model_prompt, 1, failure_prompt}
    assert [failure_prompt_operation] = value(failure_prompt, :operations)
    assert failure_prompt_operation.name == @local_operation
    assert failure_prompt_operation.parameters_schema == remote_schema

    failure_events = stream_events("parity_mcp_failure_request")

    assert Enum.count(failure_events, &(&1.event == :capability_call_failed)) == 1
    assert Enum.count(failure_events, &(&1.event == :effect_failed)) == 1
    assert Enum.count(failure_events, &(&1.event == :turn_failed)) == 1
    refute Enum.any?(failure_events, &(&1.event == :operation_observed))

    assert Enum.any?(failure_events, fn
             %Event{
               event: :capability_call_failed,
               effect_kind: :operation,
               operation: @local_operation
             } ->
               true

             _event ->
               false
           end)

    assert Enum.any?(failure_events, fn
             %Event{event: :effect_failed, effect_kind: :operation, operation: @local_operation} ->
               true

             _event ->
               false
           end)

    assert Enum.any?(failure_events, fn
             %Event{event: :turn_failed, data: %{reason: reason}} ->
               String.contains?(reason, "fake_remote_failure")

             _event ->
               false
           end)

    assert MCPRecorder.calls() == [
             {:call_tool, :parity_mcp_success, @remote_tool, model_arguments, []},
             {:call_tool, :parity_mcp_failure, @remote_tool, model_arguments, []}
           ]
  end

  defp source(endpoint) do
    MCP.new!(
      endpoint: endpoint,
      prefix: "mcp_",
      required: true,
      client: FakeMCPClient
    )
  end

  defp spec(id, operations) do
    Agent.Spec.new!(
      id: id,
      instructions: "Use the MCP customer-record tool before answering.",
      model: %{provider: :test, id: "scripted-model"},
      operations: operations,
      runtime_defaults: %{max_model_turns: 4}
    )
  end

  defp success_llm(counter, test_pid, model_arguments) do
    fn %Effect.Intent{kind: :llm, payload: payload}, %Effect.Journal{}, _context ->
      call_number = increment(counter)
      prompt = value(payload, :prompt)
      send(test_pid, {:success_model_prompt, call_number, prompt})

      case call_number do
        1 ->
          {:ok, %{type: :operation, name: @local_operation, arguments: model_arguments}}

        2 ->
          {:ok, %{type: :final, content: "Customer acct_123 is on the gold tier."}}

        unexpected ->
          raise "unexpected success-model call #{unexpected}"
      end
    end
  end

  defp failure_llm(counter, test_pid, model_arguments) do
    fn %Effect.Intent{kind: :llm, payload: payload}, %Effect.Journal{}, _context ->
      call_number = increment(counter)
      send(test_pid, {:failure_model_prompt, call_number, value(payload, :prompt)})

      if call_number == 1 do
        {:ok, %{type: :operation, name: @local_operation, arguments: model_arguments}}
      else
        {:ok, %{type: :final, content: "A failed MCP result must not reach this response."}}
      end
    end
  end

  defp increment(counter) do
    Elixir.Agent.get_and_update(counter, fn count ->
      next = count + 1
      {next, next}
    end)
  end

  defp tool_messages(prompt, operation) do
    prompt
    |> value(:messages)
    |> Enum.filter(fn message ->
      value(message, :role) == :tool and value(message, :operation) == operation
    end)
  end

  defp stream_events(request_id) do
    collect_stream_events(Jidoka.Stream.message_tag(), request_id, [])
  end

  defp collect_stream_events(tag, request_id, acc) do
    receive do
      {^tag, %Event{request_id: ^request_id} = event} ->
        collect_stream_events(tag, request_id, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp value(nil, _key), do: nil
  defp value(map, key), do: Schema.get_key(map, key)
end
