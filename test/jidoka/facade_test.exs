defmodule Jidoka.FacadeTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Turn

  test "agent/1 exposes the validated spec constructor" do
    attrs = [
      id: "facade_agent",
      instructions: "Answer through the facade.",
      model: %{provider: :test, id: "model"}
    ]

    assert {:ok, %Agent.Spec{id: "facade_agent"}} = Jidoka.agent(attrs)
  end

  test "plan/1 accepts existing plans and builds plans from specs" do
    spec =
      Jidoka.agent!(
        id: "plan_agent",
        instructions: "Plan through the facade.",
        model: %{provider: :test, id: "model"}
      )

    assert {:ok, %Turn.Plan{} = plan} = Jidoka.plan(spec)
    assert {:ok, ^plan} = Jidoka.plan(plan)
    assert Jidoka.plan!(plan) == plan
  end

  test "plan!/1 raises on invalid agent input" do
    assert_raise ArgumentError, ~r/invalid agent spec/, fn ->
      Jidoka.plan!(id: "bad_agent")
    end
  end

  test "chat/3 returns final content and resume/2 validates snapshots" do
    spec =
      Jidoka.agent!(
        id: "chat_facade_agent",
        instructions: "Chat through the facade.",
        model: %{provider: :test, id: "model"}
      )

    llm = fn _intent, _journal -> {:ok, %{type: :final, content: "facade ok"}} end

    assert {:ok, "facade ok"} = Jidoka.chat(spec, "Hello", llm: llm)
    assert {:error, _reason} = Jidoka.resume(%{}, llm: llm)
  end
end
