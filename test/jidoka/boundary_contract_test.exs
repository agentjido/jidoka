defmodule Jidoka.BoundaryContractTest.Control do
  @moduledoc false
  use Jidoka.Control, name: "boundary_control"
  def call(_context), do: :cont
end

defmodule Jidoka.BoundaryContractTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Spec
  alias Jidoka.Agent.Spec.Controls
  alias Jidoka.BoundaryContractTest.Control
  alias Jidoka.ContentPart
  alias Jidoka.Effect
  alias Jidoka.Operation.Continuation
  alias Jidoka.Turn

  test "content parts cover constructor, list, source, and projection boundaries" do
    assert ContentPart.types() == [:text, :image, :audio, :video, :document]
    assert ContentPart.schema()

    text = ContentPart.text("hello", metadata: %{source: "test"})
    assert ContentPart.source_kind(text) == :text
    assert {:ok, ^text} = ContentPart.from_input(text)

    image = ContentPart.image({:url, "https://example.com/image.png"})
    audio = ContentPart.audio({:data, "audio"})
    video = ContentPart.video({:file_id, "video-1"})
    document = ContentPart.document({:data, "document"}, filename: "file.txt")
    assert Enum.map([image, audio, video], &ContentPart.source_kind/1) == [:url, :data, :file_id]
    assert ContentPart.to_map(document).filename == "file.txt"

    assert {:ok, [^text, ^image]} = ContentPart.from_inputs([text, Map.from_struct(image)])
    assert ContentPart.text_content([text, image]) == "hello"
    assert ContentPart.summary([image, audio]) == "[Multimodal input: image, audio]"
    assert {:error, {:invalid_content_parts, []}} = ContentPart.from_inputs([])
    assert {:error, {:invalid_content_parts, :invalid}} = ContentPart.from_inputs(:invalid)
    assert {:error, _reason} = ContentPart.from_inputs([text, %{type: :text, text: ""}])

    assert_raise ArgumentError, ~r/invalid content part source/, fn ->
      ContentPart.image(:invalid)
    end

    assert_raise ArgumentError, ~r/invalid content part/, fn ->
      ContentPart.new!(type: :text, text: "")
    end

    assert {:error, {:invalid_content_part_source_count, :image, 2}} =
             ContentPart.new(type: :image, url: "https://example.com", data: "data")

    assert {:error, :text_content_part_has_media_fields} =
             ContentPart.new(type: :text, text: "hello", media_type: "text/plain")
  end

  test "LLM decisions reject all invalid final and operation forms" do
    assert_raise ArgumentError, ~r/invalid LLM decision/, fn ->
      Effect.LLMDecision.new!(type: :invalid)
    end

    final = Effect.LLMDecision.final("done")
    assert Effect.LLMDecision.first_operation(final) == nil
    assert Effect.LLMDecision.name(final) == nil
    assert Effect.LLMDecision.arguments(final) == nil
    assert Effect.LLMDecision.to_payload(final) == %{type: :final, content: "done"}

    assert {:ok, interaction_final} = Effect.LLMDecision.with_interaction(final)
    assert %Effect.ModelInteraction{} = interaction_final.interaction

    assert {:error, {:invalid_final_parts, :invalid}} =
             Effect.LLMDecision.new(type: :final, content: "done", parts: :invalid)

    assert {:error, {:invalid_final_parts, _reason}} =
             Effect.LLMDecision.new(type: :final, content: [%{type: :text, text: ""}])

    assert {:ok, multipart} =
             Effect.LLMDecision.new(
               type: :final,
               content: [ContentPart.image({:data, "image"})]
             )

    assert multipart.content == ""
    assert {:error, {:invalid_operation_name, nil}} = Effect.LLMDecision.new(type: :operation)

    assert {:error, {:invalid_operations, :invalid}} =
             Effect.LLMDecision.new(type: :operations, operations: :invalid)

    assert {:error, {:empty_operations, []}} =
             Effect.LLMDecision.new(type: :operations, operations: [])

    assert {:error, _reason} =
             Effect.LLMDecision.new(type: :operations, operations: [%{name: ""}])

    assert {:error, {:invalid_operations, :invalid}} =
             Effect.LLMDecision.new(type: :operation, operations: :invalid)

    assert {:error, {:invalid_operation_decision_count, :operation, 2}} =
             Effect.LLMDecision.new(
               type: :operation,
               operations: [%{name: "one"}, %{name: "two"}]
             )

    assert {:error, {:conflicting_operation_decision, _, _}} =
             Effect.LLMDecision.new(
               type: :operations,
               name: "one",
               operations: [%{name: "one"}, %{name: "two"}]
             )
  end

  test "memory policy supports every legacy normalization form" do
    assert Spec.Memory.scopes() == [:agent, :session]
    assert Spec.Memory.captures() == [:manual, :conversation, :off]
    assert Spec.Memory.injects() == [:instructions, :context]
    assert {:ok, nil} = Spec.Memory.from_input(nil)
    assert {:ok, nil} = Spec.Memory.from_input(false)
    assert {:ok, %Spec.Memory{}} = Spec.Memory.from_input(true)
    assert %Spec.Memory{} = Spec.Memory.new!()

    assert {:ok, %Spec.Memory{max_entries: 7}} = Spec.Memory.new(retrieve: %{limit: 7})
    assert {:ok, %Spec.Memory{max_entries: 4}} = Spec.Memory.new(max_entries: "4", retrieve: %{limit: 7})
    assert {:error, _reason} = Spec.Memory.new(max_entries: "bad")
    assert {:ok, %Spec.Memory{scope: :session}} = Spec.Memory.new(namespace: :session)

    assert {:ok, %Spec.Memory{namespace: "shared:team"}} =
             Spec.Memory.new(namespace: :shared, shared_namespace: " team ")

    assert {:ok, %Spec.Memory{namespace: nil}} = Spec.Memory.new(namespace: :shared)

    assert {:ok, %Spec.Memory{namespace: {:context, :tenant}}} =
             Spec.Memory.new(namespace: :context, context_namespace_key: :tenant)

    assert {:ok, %Spec.Memory{namespace: {:context, :tenant}}} =
             Spec.Memory.new(namespace: {:context, :tenant})

    assert {:ok, %Spec.Memory{namespace: "named"}} = Spec.Memory.new(namespace: "named")
    assert {:ok, %Spec.Memory{} = memory} = Spec.Memory.new(capture: :conversation)
    assert Spec.Memory.capture_conversation?(memory)
    refute Spec.Memory.capture_conversation?(%{memory | enabled: false})
  end

  test "control sets reject invalid scalar and nested control inputs" do
    assert {:ok, %Controls{}} = Controls.new()
    assert {:error, {:invalid_control_positive_integer, "bad"}} = Controls.new(max_turns: "bad")
    assert {:error, {:invalid_control_positive_integer, 0}} = Controls.new(timeout: 0)
    assert {:error, {:invalid_input_controls, :invalid}} = Controls.new(inputs: :invalid)
    assert {:error, {:invalid_output_controls, :invalid}} = Controls.new(outputs: :invalid)
    assert {:error, {:invalid_operation_controls, :invalid}} = Controls.new(operations: :invalid)
    assert {:error, _reason} = Controls.new(inputs: [%{control: String}])
    assert {:error, _reason} = Controls.new(operations: [%{control: String}])
    assert {:error, _reason} = Controls.new(outputs: [%{control: String}])
  end

  test "operation controls normalize and match every supported selector" do
    assert Controls.Operation.valid_kinds() |> Enum.member?(:handoff)

    control =
      Controls.Operation.new!(
        control: Control,
        match: [kind: "tool", name: :lookup, source: :catalog, idempotency: "pure", metadata: %{risk: :high}]
      )

    assert Controls.Operation.matches?(control, %{
             "operation_kind" => :tool,
             "operation" => "lookup",
             metadata: %{"risk" => "high", runtime: :catalog},
             idempotency: :pure
           })

    refute Controls.Operation.matches?(control, %{kind: :tool, name: "lookup", metadata: :invalid})
    refute Controls.Operation.matches?(control, "lookup", :tool)

    operation =
      Spec.Operation.new!(
        name: "lookup",
        idempotency: :pure,
        metadata: %{kind: :tool, source: :catalog, risk: :high}
      )

    assert Controls.Operation.matches?(control, operation)

    for match <- [
          [bad: self()],
          :invalid,
          %{unknown: true},
          %{kind: "invalid"},
          %{name: ""},
          %{name: 123},
          %{source: ""},
          %{source: 123},
          %{idempotency: "invalid"},
          %{idempotency: 123},
          %{metadata: :invalid}
        ] do
      assert {:error, _reason} = Controls.Operation.new(control: Control, match: match)
    end
  end

  test "operation continuations validate snapshots, uniqueness, and exact routes" do
    snapshot = agent_snapshot()

    attrs = [
      intent_id: "intent-1",
      operation: "delegate",
      kind: :subagent,
      source: "assistant",
      snapshot: snapshot
    ]

    assert Continuation.schema()
    assert {:ok, %Continuation{} = continuation} = Continuation.new(attrs)
    assert {:ok, ^continuation} = Continuation.from_input(continuation)
    assert {:ok, [_]} = Continuation.list_from_input([attrs])
    assert {:error, {:invalid_operation_continuations, :invalid}} = Continuation.list_from_input(:invalid)

    assert_raise ArgumentError, ~r/invalid operation continuation/, fn ->
      Continuation.new!(Keyword.put(attrs, :snapshot, :invalid))
    end

    assert {:error, {:duplicate_operation_continuation_intents, ["intent-1"]}} =
             Continuation.list_from_input([attrs, attrs])

    intent = Effect.Intent.new(:operation, %{name: "delegate"}, id: "intent-1")
    assert {:ok, ^continuation} = Continuation.find([:invalid, continuation], intent, :subagent, "assistant")
    assert Continuation.resumes_intent?([continuation], intent, :subagent, "assistant")
    assert :none = Continuation.find([continuation], intent, :subagent, "other")

    assert {:error, {:duplicate_operation_continuation, "intent-1"}} =
             Continuation.find([continuation, continuation], intent, :subagent, "assistant")

    assert Continuation.descriptor(continuation) == %{
             "intent_id" => "intent-1",
             "operation" => "delegate",
             "kind" => "subagent",
             "source" => "assistant"
           }
  end

  test "agent snapshots cover serialization, fork, and invalid input boundaries" do
    snapshot = agent_snapshot()
    assert Jidoka.Snapshot.forkable_phases() == [:after_prompt, :before_effect, :review, :wait]
    assert {:error, :invalid_snapshot_serialization} = Jidoka.Snapshot.deserialize(:invalid)
    assert {:error, :unsafe_snapshot_input} = Jidoka.Snapshot.from_input(:invalid)
    assert {:error, :unsafe_snapshot_fork_input} = Jidoka.Snapshot.fork(:invalid, [])

    assert {:error, :missing_snapshot_fork_lineage} =
             Jidoka.Snapshot.fork(snapshot, snapshot_id: "forked")

    start_snapshot = %{snapshot | cursor: Turn.Cursor.new!(), snapshot_id: "start-snapshot"}

    assert {:error, {:snapshot_not_forkable, "start-snapshot", :start}} =
             Jidoka.Snapshot.fork(start_snapshot,
               snapshot_id: "forked",
               parent_session_id: "parent",
               root_session_id: "root"
             )

    assert_raise ArgumentError, ~r/invalid agent snapshot/, fn ->
      Jidoka.Snapshot.new!(%{snapshot | schema_version: 99})
    end

    assert_raise ArgumentError, ~r/invalid serializable snapshot/, fn ->
      Jidoka.Snapshot.serialize!(%{snapshot | schema_version: 99})
    end

    state = snapshot.turn_state
    assert {:ok, %Jidoka.Snapshot{}} = Jidoka.Snapshot.from_turn_state(state, Turn.Cursor.after_prompt())
  end

  test "workflow snapshots reject unsupported, missing, conflicting, and live state" do
    cursor = Jidoka.Workflow.Loop.Cursor.new!(:loop, %{value: 1}, 3)

    snapshot = %Jidoka.Workflow.Snapshot{
      schema_version: Jidoka.Workflow.Snapshot.schema_version(),
      workflow: __MODULE__,
      workflow_id: "workflow-snapshot",
      input: %{},
      context: %{},
      steps: %{},
      outcomes: %{loop: %{status: :suspended, cursor: cursor}}
    }

    assert {:ok, binary} = Jidoka.Workflow.Snapshot.serialize(snapshot)
    assert {:ok, ^snapshot} = Jidoka.Workflow.Snapshot.deserialize(binary)
    assert {:ok, ^cursor} = Jidoka.Workflow.Snapshot.cursor(snapshot)

    assert {:error, {:unsupported_snapshot_version, 99}} =
             Jidoka.Workflow.Snapshot.serialize(%{snapshot | schema_version: 99})

    assert {:error, {:unsupported_snapshot_version, 99}} =
             Jidoka.Workflow.Snapshot.normalize(%{snapshot | schema_version: 99})

    assert {:error, {:invalid_workflow_snapshot, :invalid}} = Jidoka.Workflow.Snapshot.normalize(:invalid)
    assert {:error, {:invalid_workflow_snapshot, :invalid}} = Jidoka.Workflow.Snapshot.deserialize(:invalid)
    assert {:error, {:snapshot_deserialize_failed, _exception}} = Jidoka.Workflow.Snapshot.deserialize(<<1, 2>>)

    missing = %{snapshot | outcomes: %{}}
    assert {:error, :workflow_snapshot_missing_suspension} = Jidoka.Workflow.Snapshot.cursor(missing)
    assert {:error, :workflow_snapshot_missing_suspension} = Jidoka.Workflow.Snapshot.serialize(missing)

    other_cursor = Jidoka.Workflow.Loop.Cursor.new!(:other, %{}, 2)

    conflicting = %{
      snapshot
      | outcomes: Map.put(snapshot.outcomes, :other, %{status: :suspended, cursor: other_cursor})
    }

    assert {:error, {:multiple_workflow_suspensions, _steps}} = Jidoka.Workflow.Snapshot.cursor(conflicting)

    for {value, type} <- [
          {fn -> :ok end, :function},
          {self(), :pid},
          {make_ref(), :reference}
        ] do
      unsafe = %{snapshot | context: %{unsafe: value}}

      assert {:error, {:non_serializable_workflow_snapshot_value, [:context, :unsafe], ^type}} =
               Jidoka.Workflow.Snapshot.serialize(unsafe)
    end

    legacy = snapshot |> Map.put(:schema_version, 1) |> Map.put(:loop_cursor, cursor) |> Map.put(:outcomes, %{})

    assert {:ok, %Jidoka.Workflow.Snapshot{schema_version: 2, outcomes: outcomes}} =
             Jidoka.Workflow.Snapshot.normalize(legacy)

    assert outcomes.loop.cursor == cursor

    bad_legacy = %{legacy | loop_cursor: :invalid}

    assert {:error, {:invalid_workflow_snapshot_cursor, :invalid}} =
             Jidoka.Workflow.Snapshot.normalize(bad_legacy)
  end

  defp agent_snapshot do
    spec = Jidoka.agent!(id: "continuation-agent", instructions: "Reply.", model: %{provider: :test, id: "model"})
    plan = Turn.Plan.new!(spec)
    request = Turn.Request.new!(%{input: "hello"}, request_id: "continuation-request")
    state = Turn.State.new!(plan: plan, request: request, agent_state: request.agent_state)
    Jidoka.Snapshot.from_turn_state!(state, Turn.Cursor.after_prompt(), snapshot_id: "continuation-snapshot")
  end
end
