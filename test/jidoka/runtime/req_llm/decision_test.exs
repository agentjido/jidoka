defmodule Jidoka.Runtime.ReqLLM.DecisionTest do
  use ExUnit.Case, async: true

  alias Jidoka.Runtime.ReqLLM.Decision

  test "parses final decisions from JSON text" do
    assert {:ok, %{type: :final, content: "hello"}} =
             Decision.parse_text(~s({"type":"final","content":"hello"}))
  end

  test "parses operation decisions from JSON text" do
    assert {:ok, %{type: :operation, name: "weather", arguments: %{"city" => "Paris"}}} =
             Decision.parse_text(
               ~s({"type":"operation","name":"weather","arguments":{"city":"Paris"}})
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

    assert {:error, {:invalid_llm_decision_type, nil}} =
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
