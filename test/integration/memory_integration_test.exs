defmodule Jidoka.MemoryIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Harness
  alias Jidoka.Harness.Session
  alias Jidoka.Harness.Store.InMemory, as: SessionStore
  alias Jidoka.Memory
  alias Jidoka.Memory.Store.InMemory, as: MemoryStore
  alias Jidoka.Turn

  test "memory recall contributes to preflight and prompt assembly" do
    {:ok, pid} = MemoryStore.start_link()
    memory_store = {MemoryStore, pid: pid}
    spec = memory_spec()

    assert {:ok, %Memory.WriteResult{}} =
             Harness.write_memory(spec, "Ada prefers concise answers.",
               memory_store: memory_store,
               id_generator: fn "mem" -> "mem_ada" end
             )

    assert {:ok, preflight} =
             Jidoka.preflight(spec, "How should I answer?", memory_store: memory_store)

    assert %{memory: %{count: 1, entries: [%{content: "Ada prefers concise answers."}]}} =
             preflight.prompt

    assert Enum.map(preflight.timeline, & &1.event) == [:memory_recalled, :prompt_assembled]

    llm = fn %Effect.Intent{payload: payload}, _journal ->
      prompt = Jidoka.Schema.get_key(payload, :prompt)

      assert %{memory: %{count: 1}} = prompt
      assert memory_message?(prompt.messages, "Ada prefers concise answers.")

      {:ok, %{type: :final, content: "Concise answer."}}
    end

    assert {:ok, %Turn.Result{content: "Concise answer."} = result} =
             Jidoka.run_turn(spec, "How should I answer?", llm: llm, memory_store: memory_store)

    assert [:memory_recalled, :prompt_assembled | _rest] = Enum.map(result.events, & &1.event)
  end

  test "session-scoped memory only recalls entries for the active harness session" do
    {:ok, session_pid} = SessionStore.start_link()
    {:ok, memory_pid} = MemoryStore.start_link()
    session_store = {SessionStore, pid: session_pid}
    memory_store = {MemoryStore, pid: memory_pid}
    spec = session_memory_spec()

    assert {:ok, %Session{session_id: "sess_memory"} = session} =
             Harness.start_session(spec, session_id: "sess_memory", store: session_store)

    assert {:ok, %Memory.WriteResult{}} =
             Harness.write_memory(session, "This session is about invoice INV-123.",
               memory_store: memory_store,
               id_generator: fn "mem" -> "mem_invoice" end
             )

    assert {:ok, %Memory.WriteResult{}} =
             Harness.write_memory(spec, "Global memory should not appear for session scope.",
               memory_store: memory_store,
               id_generator: fn "mem" -> "mem_global" end
             )

    llm = fn %Effect.Intent{payload: payload}, _journal ->
      prompt = Jidoka.Schema.get_key(payload, :prompt)

      assert %{memory: %{count: 1}} = prompt
      assert memory_message?(prompt.messages, "invoice INV-123")
      refute memory_message?(prompt.messages, "Global memory")

      {:ok, %{type: :final, content: "Invoice context found."}}
    end

    assert {:ok, %Session{status: :finished}, %Turn.Result{content: "Invoice context found."}} =
             Harness.run_session("sess_memory", "What invoice is this?",
               store: session_store,
               memory_store: memory_store,
               llm: llm
             )
  end

  defp memory_spec do
    Agent.Spec.new!(
      id: "memory_agent",
      instructions: "Use recalled memory when useful.",
      model: %{provider: :test, id: "model"},
      memory: true
    )
  end

  defp session_memory_spec do
    Agent.Spec.new!(
      id: "session_memory_agent",
      instructions: "Use recalled session memory when useful.",
      model: %{provider: :test, id: "model"},
      memory: %{scope: :session, max_entries: 3}
    )
  end

  defp memory_message?(messages, expected) do
    Enum.any?(messages, fn message ->
      content = Map.get(message, :content) || Map.get(message, "content") || ""
      String.contains?(content, expected)
    end)
  end
end
