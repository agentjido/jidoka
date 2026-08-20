defmodule Jidoka.Adapter.ReqLLM.DecisionTest do
  use ExUnit.Case, async: true

  alias Jidoka.Adapter.ReqLLM.Decision

  test "parses final decisions from JSON text" do
    assert {:ok, %{type: :final, content: "hello"}} =
             Decision.parse_text(~s({"type":"final","content":"hello"}))
  end

  test "parses structured result values from final decisions" do
    assert {:ok, %{type: :final, content: "hello", result: %{"answer" => "Ada"}}} =
             Decision.parse_text(~s({"type":"final","content":"hello","result":{"answer":"Ada"}}))
  end

  test "parses untyped structured result objects as final decisions" do
    assert {:ok,
            %{
              type: :final,
              content: "Brief summary",
              result: %{
                "summary" => "Brief summary",
                "sources" => [%{"url" => "https://example.com"}]
              }
            }} =
             Decision.parse_text(~s({"summary":"Brief summary","sources":[{"url":"https://example.com"}]}))
  end

  test "parses operation decisions from JSON text" do
    assert {:ok, decision} =
             Decision.parse_text(~s({"type":"operation","name":"weather","arguments":{"city":"Paris"}}))

    assert_operation(decision, "weather", %{"city" => "Paris"})
  end

  test "normalizes common tool call aliases to operation decisions" do
    assert {:ok, decision} =
             Decision.parse_text(~s({"type":"tool","name":"weather","arguments":{"city":"Paris"}}))

    assert_operation(decision, "weather", %{"city" => "Paris"})

    assert {:ok, decision} = Decision.parse_text(~s({"type":"function_call","name":"weather"}))
    assert_operation(decision, "weather", %{})

    assert {:ok, decision} = Decision.parse_text(~s({"type":"tool_call","name":"weather"}))
    assert_operation(decision, "weather", %{})

    assert {:ok, decision} = Decision.parse_text(~s({"type":"action","name":"weather"}))
    assert_operation(decision, "weather", %{})
  end

  test "normalizes operation-name shorthand when arguments are present" do
    assert {:ok, decision} =
             Decision.parse_text(~s({"type":"read_page","url":"https://example.com"}))

    assert_operation(decision, "read_page", %{"url" => "https://example.com"})

    assert {:ok, decision} =
             Decision.parse_text(~s({"type":"search_web","params":{"query":"runic"}}))

    assert_operation(decision, "search_web", %{"query" => "runic"})

    assert {:ok, decision} =
             Decision.parse_text(~s({"name":"read_page","arguments":{"url":"https://example.com"}}))

    assert_operation(decision, "read_page", %{"url" => "https://example.com"})

    assert {:ok, decision} =
             Decision.parse_text(~s({"tool_call":{"name":"read_page","arguments":{"url":"https://example.com"}}}))

    assert_operation(decision, "read_page", %{"url" => "https://example.com"})
  end

  test "parses batched operation decisions" do
    assert {:ok,
            %{
              type: :operations,
              operations: [
                %{name: "lookup_order", arguments: %{"order_id" => "A1001"}},
                %{name: "lookup_customer", arguments: %{"customer_id" => "C42"}}
              ]
            }} =
             Decision.parse_text(
               ~s({"type":"operations","operations":[{"name":"lookup_order","arguments":{"order_id":"A1001"}},{"name":"lookup_customer","arguments":{"customer_id":"C42"}}]})
             )

    assert {:ok,
            %{
              type: :operations,
              operations: [
                %{name: "lookup_order", arguments: %{"order_id" => "A1001"}},
                %{name: "lookup_customer", arguments: %{"customer_id" => "C42"}}
              ]
            }} =
             Decision.parse_text(
               ~s({"tool_calls":[{"function":{"name":"lookup_order","arguments":"{\\"order_id\\":\\"A1001\\"}"}},{"function":{"name":"lookup_customer","arguments":{"customer_id":"C42"}}}]})
             )
  end

  test "parses JSON decisions from markdown fences and surrounding text" do
    assert {:ok, %{type: :final, content: "fenced"}} =
             Decision.parse_text("""
             ```json
             {"type":"final","content":"fenced"}
             ```
             """)

    assert {:ok, decision} =
             Decision.parse_text(~s(The answer is {"type":"operation","name":"lookup"} thanks))

    assert_operation(decision, "lookup", %{})
  end

  test "falls back to final text when no JSON object is present" do
    assert {:ok, %{type: :final, content: "plain answer"}} =
             Decision.parse_text(" plain answer ")
  end

  test "rejects empty and malformed decision objects" do
    assert {:error, :empty_llm_response} = Decision.parse_text(nil)

    assert {:ok, %{type: :final, content: "missing type"}} =
             Decision.parse_text(~s({"content":"missing type"}))

    assert {:error, {:invalid_llm_decision_type, "bad"}} =
             Decision.parse_text(~s({"type":"bad"}))
  end

  test "rejects malformed final decisions" do
    assert {:error, {:invalid_final_content, 123}} =
             Decision.parse_text(~s({"type":"final","content":123}))
  end

  test "rejects malformed operation decisions" do
    assert {:error, {:invalid_operation_name, nil}} =
             Decision.parse_text(~s({"type":"operation","arguments":{}}))

    assert {:error, {:invalid_operation_name, 123}} =
             Decision.parse_text(~s({"type":"operation","name":123,"arguments":{}}))

    assert {:error, {:invalid_operation_arguments, "bad"}} =
             Decision.parse_text(~s({"type":"operation","name":"weather","arguments":"bad"}))

    assert {:error, {:empty_operations, []}} =
             Decision.parse_text(~s({"type":"operations","operations":[]}))

    assert {:error, {:invalid_operation_name, nil}} =
             Decision.parse_text(~s({"type":"operations","operations":[{"arguments":{}}]}))
  end

  test "rejects JSON arrays as decision protocol but falls back only for non-json text" do
    assert {:ok, %{type: :final, content: "[1,2,3]"}} = Decision.parse_text("[1,2,3]")
  end

  test "parses already decoded object maps with atom or string keys" do
    assert {:ok, %{type: :final, content: "atom keyed"}} =
             Decision.parse_object(%{type: "final", content: "atom keyed"})

    assert {:ok, decision} =
             Decision.parse_object(%{"type" => "operation", "name" => "lookup"})

    assert_operation(decision, "lookup", %{})
  end

  test "normalizes every batched operation alias" do
    for key <- [:tools, :function_calls, :actions] do
      object = %{key => [%{name: "lookup", arguments: %{id: "A-1"}}]}

      assert {:ok, %{type: :operations, operations: [%{name: "lookup"}]}} =
               Decision.parse_object(object)
    end

    assert {:error, {:invalid_operation_request, :invalid}} =
             Decision.parse_object(%{type: "operations", operations: [:invalid]})
  end

  test "normalizes nested operation name and argument aliases" do
    cases = [
      %{tool: %{operation: "lookup", params: %{id: 1}}},
      %{function_call: %{tool: "lookup", parameters: %{id: 1}}},
      %{function: %{tool_name: "lookup", args: %{id: 1}}}
    ]

    Enum.each(cases, fn object ->
      assert {:ok, decision} = Decision.parse_object(object)
      assert_operation(decision, "lookup", %{id: 1})
    end)

    assert {:ok, %{type: :operations, operations: [%{name: "lookup", arguments: %{id: 1}}]}} =
             Decision.parse_object(%{
               tool_calls: [%{function_name: "lookup", arguments: %{id: 1}}]
             })
  end

  test "encodes an untyped object when no summary is present" do
    assert {:ok, %{type: :final, content: content, result: %{answer: 42}}} =
             Decision.parse_object(%{answer: 42})

    assert Jason.decode!(content) == %{"answer" => 42}

    assert {:error, {:invalid_llm_decision_type, :final}} =
             Decision.parse_object(%{type: :final, content: "invalid atom type"})
  end

  test "does not recurse when malformed text contains the full candidate object" do
    assert {:ok, %{type: :final, content: "{invalid}"}} = Decision.parse_text("{invalid}")
  end

  defp assert_operation(decision, name, arguments) do
    assert decision.type == :operation
    assert [operation] = decision.operations
    assert operation.name == name
    assert operation.arguments == arguments
  end
end
