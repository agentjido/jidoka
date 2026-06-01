defmodule Jidoka.MinimalDslIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Effect
  alias Jidoka.IntegrationSupport.MinimalChatAgent

  import Jidoka.TestSupport, only: [count_results: 2]

  test "bare DSL agent can make one chat call without tools" do
    assert MinimalChatAgent.__jidoka_agent__().instructions == Jidoka.Agent.default_instructions()
    assert MinimalChatAgent.__jidoka_agent__().actions == []
    assert MinimalChatAgent.spec().operations == []

    llm = fn intent, %Effect.Journal{} = journal ->
      assert count_results(journal, :llm) == 0

      prompt = Jidoka.Schema.get_key(intent.payload, :prompt)
      assert Jidoka.Schema.get_key(prompt, :operations) == []

      assert [
               %{role: :system, content: "You are a helpful assistant."},
               %{role: :user, content: "Say hello"}
             ] = Jidoka.Schema.get_key(prompt, :messages)

      {:ok, %{type: :final, content: "Hello from a minimal Jidoka agent."}}
    end

    assert {:ok, "Hello from a minimal Jidoka agent."} =
             MinimalChatAgent.chat("Say hello", llm: llm)
  end

  test "bare DSL agent rejects model-requested operations cleanly" do
    llm = fn _intent, %Effect.Journal{} ->
      {:ok, %{type: :operation, name: "lookup_order", arguments: %{"order_id" => "order_123"}}}
    end

    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :operation,
              details: %{reason: :unknown_operation, operation_name: "lookup_order"}
            }} = MinimalChatAgent.run_turn("Look up order order_123", llm: llm)
  end
end
