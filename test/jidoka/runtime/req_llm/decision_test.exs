defmodule Jidoka.Runtime.ReqLLM.DecisionTest do
  use ExUnit.Case, async: true

  alias Jidoka.Runtime.ReqLLM.Decision

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
    assert {:ok, %{type: :operation, name: "weather", arguments: %{"city" => "Paris"}}} =
             Decision.parse_text(~s({"type":"operation","name":"weather","arguments":{"city":"Paris"}}))
  end

  test "normalizes common tool call aliases to operation decisions" do
    assert {:ok, %{type: :operation, name: "weather", arguments: %{"city" => "Paris"}}} =
             Decision.parse_text(~s({"type":"tool","name":"weather","arguments":{"city":"Paris"}}))

    assert {:ok, %{type: :operation, name: "weather", arguments: %{}}} =
             Decision.parse_text(~s({"type":"function_call","name":"weather"}))

    assert {:ok, %{type: :operation, name: "weather", arguments: %{}}} =
             Decision.parse_text(~s({"type":"tool_call","name":"weather"}))

    assert {:ok, %{type: :operation, name: "weather", arguments: %{}}} =
             Decision.parse_text(~s({"type":"action","name":"weather"}))
  end

  test "normalizes operation-name shorthand when arguments are present" do
    assert {:ok, %{type: :operation, name: "read_page", arguments: %{"url" => "https://example.com"}}} =
             Decision.parse_text(~s({"type":"read_page","url":"https://example.com"}))

    assert {:ok, %{type: :operation, name: "search_web", arguments: %{"query" => "runic"}}} =
             Decision.parse_text(~s({"type":"search_web","params":{"query":"runic"}}))

    assert {:ok, %{type: :operation, name: "read_page", arguments: %{"url" => "https://example.com"}}} =
             Decision.parse_text(~s({"name":"read_page","arguments":{"url":"https://example.com"}}))

    assert {:ok, %{type: :operation, name: "read_page", arguments: %{"url" => "https://example.com"}}} =
             Decision.parse_text(~s({"tool_call":{"name":"read_page","arguments":{"url":"https://example.com"}}}))
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

    assert {:ok, %{type: :operation, name: "lookup", arguments: %{}}} =
             Decision.parse_text(~s(The answer is {"type":"operation","name":"lookup"} thanks))
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

    assert {:ok, %{type: :operation, name: "lookup", arguments: %{}}} =
             Decision.parse_object(%{"type" => "operation", "name" => "lookup"})
  end
end
