defmodule JidokaTest.Support.LocalTimeAction do
  use Jidoka.Action,
    name: "local_time",
    description: "Returns a deterministic local time for a city.",
    schema:
      Zoi.object(%{
        city: Zoi.string() |> Zoi.default("Chicago")
      })

  @impl true
  def run(params, context) do
    city = Map.get(params, :city) || Map.get(params, "city") || "Chicago"

    if pid = context[:test_pid] do
      send(pid, {:local_time_called, city})
    end

    {:ok,
     %{
       city: city,
       time: "09:30",
       canary: "jidoka_dsl_tool_canary",
       jido_agent_name: context.agent_module.name()
     }}
  end
end

defmodule JidokaTest.Support.TimeAgent do
  use Jidoka.Agent

  agent :dsl_time_agent do
    model %{provider: :test, id: "model"}
    instructions "Use local_time when asked for the time."
  end

  tools do
    action JidokaTest.Support.LocalTimeAction
  end
end

defmodule JidokaTest do
  use ExUnit.Case, async: true

  alias Jidoka.Runtime.LocalOperations
  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Effect
  alias Jidoka.Turn
  alias JidokaTest.Support.TimeAgent

  test "top-level API builds agents, plans, and runs string turns" do
    default_model = Jidoka.Config.default_model()

    spec =
      Jidoka.agent!(
        id: "echo_agent",
        instructions: "Echo tersely.",
        runtime_defaults: %{max_model_turns: 1}
      )

    plan = Jidoka.plan!(spec)

    llm = fn intent, _journal ->
      assert Jidoka.Config.model_ref(intent.payload.model) ==
               Jidoka.Config.model_ref(default_model)

      assert intent.payload.prompt.model == Jidoka.Config.model_ref(default_model)
      {:ok, %{type: :final, content: "echo"}}
    end

    assert {:ok, %Turn.Result{content: "echo"}} = Jidoka.Harness.run_turn(plan, "Echo", llm: llm)
    assert {:ok, %Turn.Result{content: "echo"}} = Jidoka.run_turn(plan, "Echo", llm: llm)
    assert {:ok, "echo"} = Jidoka.chat(spec, "Echo", capabilities: [llm: llm])
    assert {:ok, "echo"} = Jidoka.chat(spec, "Echo", adapters: [llm: llm])
  end

  test "agent specs are normalized through Zoi schemas" do
    assert {:ok, %Agent.Spec{} = spec} =
             Agent.Spec.new(%{
               "id" => :weather_agent,
               "instructions" => "Use tools when useful.",
               "operations" => [
                 %{"name" => :weather, "description" => "Looks up weather by city."}
               ],
               "runtime_defaults" => %{"max_model_turns" => 2}
             })

    assert spec.id == "weather_agent"

    assert Jidoka.Config.model_ref(spec.model) ==
             Jidoka.Config.model_ref(Jidoka.Config.default_model())

    assert spec.generation.params == %{temperature: 0.0, max_tokens: 500}
    assert [%Operation{name: "weather", idempotency: :idempotent}] = spec.operations
    assert Jidoka.compile_turn_plan!(spec).max_model_turns == 2

    assert {:error, [%Zoi.Error{path: [:operations, 0, :idempotency]}]} =
             Agent.Spec.new(%{
               id: "bad_agent",
               instructions: "Invalid tool.",
               operations: [%{name: "weather", idempotency: :not_an_idempotency}]
             })

    assert {:error, {:model, :fast, _message}} =
             Agent.Spec.new(%{
               id: "bad_model_agent",
               instructions: "Invalid model.",
               model: :fast
             })
  end

  test "runs a minimal ReAct-style tool loop through effect intents" do
    spec =
      Agent.Spec.new!(
        id: "weather_agent",
        instructions: "Use tools when useful, then answer.",
        operations: [
          Operation.new!(
            name: "weather",
            description: "Looks up weather by city.",
            idempotency: :idempotent
          )
        ],
        runtime_defaults: %{max_model_turns: 4}
      )

    llm = fn _intent, %Effect.Journal{} = journal ->
      llm_calls = count_results(journal, :llm)

      case llm_calls do
        0 ->
          {:ok, %{type: :operation, name: "weather", arguments: %{"city" => "Paris"}}}

        1 ->
          {:ok, %{type: :final, content: "The weather in Paris is sunny."}}
      end
    end

    operations =
      LocalOperations.operations(%{
        weather: fn intent, _journal ->
          assert intent.payload.name == "weather"
          assert intent.idempotency == :idempotent
          assert is_binary(intent.idempotency_key)
          {:ok, %{city: intent.payload.arguments["city"], condition: "sunny"}}
        end
      })

    assert {:ok, %Turn.Result{} = result} =
             Jidoka.run_turn(spec, Turn.Request.new!(input: "Weather in Paris?"),
               llm: llm,
               operations: operations
             )

    assert result.content == "The weather in Paris is sunny."
    assert Enum.count(result.journal.results) == 3
    assert [%Effect.OperationResult{operation: "weather"}] = result.agent_state.operation_results
  end

  test "minimal agent DSL compiles to a Jido-backed tool loop" do
    assert %Jido.Agent{name: "dsl_time_agent"} = TimeAgent.new()

    assert %{
             id: "dsl_time_agent",
             model: %LLMDB.Model{} = model,
             instructions: "Use local_time when asked for the time.",
             actions: [JidokaTest.Support.LocalTimeAction]
           } = TimeAgent.__jidoka_agent__()

    assert Jidoka.Config.model_ref(model) == "test:model"

    spec = TimeAgent.spec()
    assert spec.id == "dsl_time_agent"
    assert Jidoka.Config.model_ref(spec.model) == "test:model"
    assert [%Operation{name: "local_time"} = operation] = spec.operations
    assert is_map(operation.metadata["parameters_schema"])

    llm = fn _intent, %Effect.Journal{} = journal ->
      case count_results(journal, :llm) do
        0 ->
          {:ok, %{type: :operation, name: "local_time", arguments: %{"city" => "Chicago"}}}

        1 ->
          {:ok, %{type: :final, content: "Chicago time is 09:30."}}
      end
    end

    assert {:ok, "Chicago time is 09:30."} =
             TimeAgent.chat("What time is it in Chicago?",
               llm: llm,
               operation_context: %{test_pid: self()}
             )

    assert_received {:local_time_called, "Chicago"}
    refute_received {:local_time_called, _city}
  end

  test "hibernates at a phase boundary and resumes from the snapshot" do
    default_model = Jidoka.Config.default_model()

    spec =
      Agent.Spec.new!(
        id: "chat_agent",
        instructions: "Answer tersely.",
        runtime_defaults: %{max_model_turns: 2}
      )

    llm = fn intent, _journal ->
      model = Map.get(intent.payload, :model) || Map.get(intent.payload, "model")

      assert Jidoka.Config.model_ref(model) == Jidoka.Config.model_ref(default_model)

      {:ok, %{"type" => "final", "content" => "hello"}}
    end

    operations = fn _intent, _journal ->
      {:error, :unexpected_operation}
    end

    assert {:hibernate, %AgentSnapshot{} = snapshot} =
             Jidoka.run_turn(spec, Turn.Request.new!(input: "Say hello"),
               llm: llm,
               operations: operations,
               checkpoint: :after_prompt
             )

    assert snapshot.cursor.phase == :after_prompt
    assert snapshot.turn_state.pending_effect.kind == :llm

    assert {:ok, %AgentSnapshot{} = restored_snapshot} =
             snapshot
             |> portable_map()
             |> AgentSnapshot.new()

    assert {:ok, %Turn.Result{content: "hello"} = result} =
             Jidoka.resume(restored_snapshot, llm: llm, operations: operations)

    assert [%Effect.Result{kind: :llm, status: :ok}] = Map.values(result.journal.results)
  end

  test "checkpoint after each phase can pause before a planned operation" do
    spec =
      Agent.Spec.new!(
        id: "checkpoint_agent",
        instructions: "Use weather once.",
        operations: [
          Operation.new!(
            name: "weather",
            description: "Looks up weather by city.",
            idempotency: :idempotent
          )
        ],
        runtime_defaults: %{max_model_turns: 4}
      )

    llm = fn _intent, %Effect.Journal{} = journal ->
      case count_results(journal, :llm) do
        0 -> {:ok, %{type: :operation, name: "weather", arguments: %{"city" => "Paris"}}}
        1 -> {:ok, %{type: :final, content: "Paris is sunny."}}
      end
    end

    operations =
      LocalOperations.operations(%{
        weather: fn intent, _journal ->
          arguments = Jidoka.Schema.get_key(intent.payload, :arguments)
          {:ok, %{city: arguments["city"], condition: "sunny"}}
        end
      })

    assert {:hibernate, %AgentSnapshot{} = prompt_snapshot} =
             Jidoka.run_turn(spec, Turn.Request.new!(input: "Weather in Paris?"),
               llm: llm,
               operations: operations,
               checkpoint: :after_each_phase
             )

    assert prompt_snapshot.cursor.phase == :after_prompt
    assert prompt_snapshot.turn_state.pending_effect.kind == :llm

    assert {:hibernate, %AgentSnapshot{} = operation_snapshot} =
             Jidoka.resume(prompt_snapshot,
               llm: llm,
               operations: operations,
               checkpoint: :after_each_phase
             )

    assert operation_snapshot.cursor.phase == :before_effect
    assert operation_snapshot.cursor.metadata["effect_kind"] == :operation
    assert operation_snapshot.turn_state.pending_effect.kind == :operation

    assert {:ok, %AgentSnapshot{} = restored_operation_snapshot} =
             operation_snapshot
             |> portable_map()
             |> AgentSnapshot.new()

    assert {:ok, %Turn.Result{content: "Paris is sunny."}} =
             Jidoka.resume(restored_operation_snapshot, llm: llm, operations: operations)
  end

  test "context schemas are enforced before the turn runs" do
    spec =
      Agent.Spec.new!(
        id: "context_agent",
        instructions: "Use tenant context.",
        context_schema: Zoi.object(%{tenant_id: Zoi.string()})
      )

    llm = fn _intent, _journal -> {:ok, %{type: :final, content: "ok"}} end

    assert {:error, %Jidoka.Error.ValidationError{field: :context}} =
             Jidoka.run_turn(spec, Turn.Request.new!(input: "Hello", context: %{}), llm: llm)

    assert {:ok, %Turn.Result{content: "ok"}} =
             Jidoka.run_turn(
               spec,
               Turn.Request.new!(input: "Hello", context: %{tenant_id: "tenant_123"}),
               llm: llm
             )
  end

  defp count_results(%Effect.Journal{results: results}, kind) do
    Enum.count(results, fn {_id, %Effect.Result{kind: result_kind}} -> result_kind == kind end)
  end

  defp portable_map(%_{} = value), do: value |> Map.from_struct() |> portable_map()

  defp portable_map(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), portable_map(nested)} end)
  end

  defp portable_map(value) when is_list(value), do: Enum.map(value, &portable_map/1)
  defp portable_map(value), do: value
end
