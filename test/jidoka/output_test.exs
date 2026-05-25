defmodule JidokaTest.OutputTest do
  use JidokaTest.Support.Case, async: false

  alias Jido.AI.Request
  alias Jidoka.Output
  alias JidokaTest.{ChatAgent, StructuredOutputAgent, StructuredOutputPlainAgent}

  @schema Zoi.object(%{
            category: Zoi.enum([:billing, :technical, :account]),
            confidence: Zoi.float() |> Zoi.default(1.0),
            summary: Zoi.string()
          })

  test "builds an agent-level result contract and exposes generated helpers" do
    assert %Output{schema_kind: :zoi, retries: 1, on_validation_error: :repair} =
             StructuredOutputAgent.result()

    assert StructuredOutputAgent.result_schema() == StructuredOutputAgent.result().schema
    assert StructuredOutputAgent.__jidoka__().result == StructuredOutputAgent.result()
    refute function_exported?(StructuredOutputAgent, :output, 0)
    refute function_exported?(StructuredOutputAgent, :output_schema, 0)
  end

  test "typed result contracts expose instructions and JSON Schema" do
    result = StructuredOutputAgent.result()

    assert Output.instructions(result) =~ "Return the final answer as a single JSON object"

    assert %{
             "type" => "object",
             "required" => required,
             "properties" => properties
           } = Output.json_schema(result)

    assert Enum.sort(required) == ["category", "confidence", "summary"]
    assert properties["category"]["enum"] == ["billing", "technical", "account"]
    assert properties["confidence"]["type"] == "number"
    assert properties["summary"]["type"] == "string"
  end

  test "parses JSON text and validates through Zoi with normalized keys and atom enums" do
    {:ok, output} = Output.new(schema: @schema)

    assert {:ok, parsed} =
             Output.parse(output, ~s({"category":"billing","confidence":0.91,"summary":"Refund request"}))

    assert parsed == %{category: :billing, confidence: 0.91, summary: "Refund request"}
  end

  test "parses response objects, object wrappers, and markdown-fenced JSON" do
    {:ok, output} = Output.new(object_schema: @schema)

    response = %ReqLLM.Response{
      id: "response-output",
      model: "test",
      context: nil,
      object: %{"category" => "account", "confidence" => 0.82, "summary" => "Password reset"}
    }

    assert {:ok, %{category: :account, confidence: 0.82, summary: "Password reset"}} =
             Output.parse(output, response)

    assert {:ok, %{category: :billing, confidence: 0.91, summary: "Refund request"}} =
             Output.parse(output, %{
               object: %{"category" => "billing", "confidence" => 0.91, "summary" => "Refund request"}
             })

    assert {:ok, %{category: :technical, confidence: 0.77, summary: "Login failure"}} =
             Output.parse(output, """
             ```JSON
             {"category":"technical","confidence":0.77,"summary":"Login failure"}
             ```
             """)
  end

  test "applies Zoi defaults and returns normalized output validation errors" do
    {:ok, output} = Output.new(schema: @schema)

    assert {:ok, %{category: :technical, confidence: 1.0, summary: "Login is failing"}} =
             Output.validate(output, %{"category" => "technical", "summary" => "Login is failing"})

    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Output.parse(output, "not json")

    assert error.field == :output
    assert error.details.reason |> elem(0) == :parse
    assert error.details.raw_preview == "not json"
  end

  test "redacts sensitive values in output error previews" do
    {:ok, output} = Output.new(schema: @schema)

    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Output.validate(output, %{api_key: "secret-value", nested: %{token: "hidden-value"}})

    assert error.details.raw_preview =~ "[REDACTED]"
    refute error.details.raw_preview =~ "secret-value"
    refute error.details.raw_preview =~ "hidden-value"
  end

  test "normalizes retry bounds and validation modes" do
    assert {:ok, %Output{retries: 3}} = Output.new(schema: @schema, retries: 10)
    assert {:ok, %Output{on_validation_error: :error}} = Output.new(schema: @schema, on_validation_error: "error")
    assert {:error, _reason} = Output.new(schema: @schema, retries: -1)
    assert {:error, _reason} = Output.new(schema: @schema, on_validation_error: :retry_forever)
    assert {:error, _reason} = Output.new(schema: Zoi.string())
  end

  test "adds structured output instructions to transformed requests" do
    runtime = StructuredOutputAgent.runtime_module()
    agent = new_runtime_agent(runtime)
    request_id = "req-output-transformer"

    assert {:ok, _agent, {:ai_react_start, params}} =
             runtime.on_before_cmd(
               agent,
               {:ai_react_start, %{query: "Classify this", request_id: request_id, tool_context: %{}}}
             )

    request = react_request([%{role: :user, content: "Classify this"}])
    transformer = StructuredOutputAgent.request_transformer()

    assert {:ok, %{messages: [%{role: :system, content: prompt}, %{role: :user, content: "Classify this"}]}} =
             transformer.transform_request(request, react_state(), react_config(transformer), params.tool_context)

    assert prompt =~ "Structured output:"
    assert prompt =~ "Return the final answer as a single JSON object"
    assert prompt =~ "category"
  end

  test "finalizes completed runtime requests before output guardrails run" do
    runtime = StructuredOutputAgent.runtime_module()
    request_id = "req-output-runtime"

    agent =
      runtime
      |> new_runtime_agent()
      |> Request.start_request(request_id, "Classify this")

    {:ok, agent, {:ai_react_start, params}} =
      runtime.on_before_cmd(
        agent,
        {:ai_react_start,
         %{
           query: "Classify this",
           request_id: request_id,
           tool_context: %{
             notify_pid: self(),
             session: "output-session",
             conversation_id: "output-conversation",
             context_ref: "output-context"
           }
         }}
      )

    agent =
      agent
      |> Request.complete_request(request_id, ~s({"category":"account","confidence":0.74,"summary":"Password reset"}))

    assert {:ok, agent, []} = runtime.on_after_cmd(agent, {:ai_react_start, params}, [])

    assert {:ok, %{category: :account, confidence: 0.74, summary: "Password reset"}} =
             Request.get_result(agent, request_id)

    assert_receive {:structured_output_guardrail, {:ok, %{category: :account}}}
    assert get_in(agent.state, [:requests, request_id, :meta, :jidoka_output, :status]) == :validated

    assert {:ok, trace} = Jidoka.Trace.for_request(agent.id, request_id)

    assert Enum.any?(trace.events, fn event ->
             event.category == :output and event.event == :validated and
               event.metadata.session_id == "output-session" and
               event.metadata.conversation_id == "output-conversation" and
               event.metadata.context_ref == "output-context"
           end)
  end

  test "finalizes completed requests from generic runtime completion actions" do
    runtime = StructuredOutputAgent.runtime_module()
    request_id = "req-output-generic-runtime"

    {:ok, agent, {:ai_react_start, _params}} =
      runtime.on_before_cmd(
        runtime.new(id: "generic-output-runtime-agent"),
        {:ai_react_start, %{query: "Classify this", request_id: request_id, tool_context: %{}}}
      )

    agent =
      agent
      |> Request.complete_request(request_id, ~s({"category":"billing","confidence":0.81,"summary":"Invoice issue"}))

    assert {:ok, agent, []} = runtime.on_after_cmd(agent, {:ai_react_runtime_event, %{kind: :request_completed}}, [])

    assert {:ok, %{category: :billing, confidence: 0.81, summary: "Invoice issue"}} =
             Request.get_result(agent, request_id)
  end

  test "repair is invoked when initial output parsing fails" do
    output = StructuredOutputAgent.result()
    request_id = "req-output-repair"

    agent =
      StructuredOutputAgent.runtime_module()
      |> new_runtime_agent()
      |> Request.start_request(request_id, "Classify this")
      |> Request.complete_request(request_id, "billing issue with high confidence")

    repair_fun = fn _output, _agent, _context, raw, reason ->
      send(self(), {:repair_invoked, raw, reason})
      {:ok, %{"category" => "billing", "confidence" => 0.88, "summary" => "Billing issue"}}
    end

    agent = Output.finalize(agent, request_id, output, context: %{}, repair_fun: repair_fun)

    assert_receive {:repair_invoked, "billing issue with high confidence", %Jidoka.Error.ValidationError{}}

    assert {:ok, %{category: :billing, confidence: 0.88, summary: "Billing issue"}} =
             Request.get_result(agent, request_id)

    assert %{
             status: :repaired,
             attempt: 1,
             raw_preview: "billing issue with high confidence",
             validation_error: validation_error
           } = get_in(agent.state, [:requests, request_id, :meta, :jidoka_output])

    assert is_binary(validation_error)
  end

  test "output raw mode bypasses structured finalization" do
    runtime = StructuredOutputAgent.runtime_module()
    request_id = "req-output-raw"

    {:ok, context} =
      [context: %{}, output: :raw]
      |> Jidoka.Agent.prepare_chat_opts(StructuredOutputAgent.__jidoka__())
      |> case do
        {:ok, opts} -> {:ok, Keyword.fetch!(opts, :tool_context)}
        other -> other
      end

    {:ok, agent, {:ai_react_start, params}} =
      runtime.on_before_cmd(
        new_runtime_agent(runtime),
        {:ai_react_start, %{query: "Classify this", request_id: request_id, tool_context: context}}
      )

    agent =
      agent
      |> Request.start_request(request_id, "Classify this")
      |> Request.complete_request(request_id, "raw assistant answer")

    assert {:ok, agent, []} = Output.on_after_cmd(agent, {:ai_react_start, params}, [], StructuredOutputAgent.result())
    assert {:ok, "raw assistant answer"} = Request.get_result(agent, request_id)
  end

  test "output raw mode bypasses result controls in generated runtimes" do
    runtime = StructuredOutputAgent.runtime_module()
    request_id = "req-output-raw-runtime"

    {:ok, context} =
      [context: %{notify_pid: self()}, output: :raw]
      |> Jidoka.Agent.prepare_chat_opts(StructuredOutputAgent.__jidoka__())
      |> case do
        {:ok, opts} -> {:ok, Keyword.fetch!(opts, :tool_context)}
        other -> other
      end

    {:ok, agent, {:ai_react_start, params}} =
      runtime.on_before_cmd(
        new_runtime_agent(runtime),
        {:ai_react_start, %{query: "Classify this", request_id: request_id, tool_context: context}}
      )

    agent =
      agent
      |> Request.start_request(request_id, "Classify this")
      |> Request.complete_request(request_id, "raw assistant answer")

    assert {:ok, agent, []} = runtime.on_after_cmd(agent, {:ai_react_start, params}, [])
    assert {:ok, "raw assistant answer"} = Request.get_result(agent, request_id)
    refute_received {:structured_output_guardrail, _outcome}
  end

  test "output raw mode also bypasses generic runtime completion finalization" do
    runtime = StructuredOutputPlainAgent.runtime_module()
    request_id = "req-output-raw-generic"

    {:ok, context} =
      [context: %{}, output: :raw]
      |> Jidoka.Agent.prepare_chat_opts(StructuredOutputPlainAgent.__jidoka__())
      |> case do
        {:ok, opts} -> {:ok, Keyword.fetch!(opts, :tool_context)}
        other -> other
      end

    {:ok, agent, {:ai_react_start, _params}} =
      runtime.on_before_cmd(
        runtime.new(id: "generic-output-raw-agent"),
        {:ai_react_start, %{query: "Classify this", request_id: request_id, tool_context: context}}
      )

    agent = Request.complete_request(agent, request_id, "raw assistant answer")

    assert {:ok, agent, []} = runtime.on_after_cmd(agent, {:ai_react_runtime_event, %{kind: :request_completed}}, [])
    assert {:ok, "raw assistant answer"} = Request.get_result(agent, request_id)
  end

  test "output runtime no-ops without contracts, start actions, or completed requests" do
    runtime = StructuredOutputPlainAgent.runtime_module()
    output = StructuredOutputPlainAgent.result()
    agent = new_runtime_agent(runtime)

    assert {:ok, ^agent, {:not_react, %{}}} = Output.on_before_cmd(agent, {:not_react, %{}}, output)
    assert {:ok, ^agent, [:directive]} = Output.on_after_cmd(agent, {:not_react, %{}}, [:directive], nil)
    assert Output.finalize(agent, "missing-request", output) == agent

    request_id = "req-output-not-completed"

    agent =
      agent
      |> Request.start_request(request_id, "Classify this")

    assert Output.finalize(agent, request_id, output) == agent
  end

  test "output runtime records context and rebuilds it from request metadata" do
    runtime = StructuredOutputPlainAgent.runtime_module()
    request_id = "req-output-context-fallback"

    {:ok, agent, {:ai_react_start, _params}} =
      Output.on_before_cmd(
        runtime
        |> new_runtime_agent()
        |> Request.start_request(request_id, "Classify this"),
        {:ai_react_start,
         %{
           query: "Classify this",
           request_id: request_id,
           llm_opts: [tools: [:removed], temperature: 0],
           tool_context: %{},
           runtime_context: %{}
         }},
        StructuredOutputPlainAgent.result()
      )

    assert get_in(agent.state, [:requests, request_id, :meta, :jidoka_output_runtime, :mode]) == :structured

    assert get_in(agent.state, [:requests, request_id, :meta, :jidoka_output_runtime, :llm_opts]) == [
             tools: [:removed],
             temperature: 0
           ]

    agent =
      agent
      |> Request.complete_request(request_id, ~s({"category":"technical","confidence":0.64,"summary":"Bug report"}))

    assert {:ok, agent, []} =
             Output.on_after_cmd(
               agent,
               {:ai_react_runtime_event, %{kind: :request_completed}},
               [],
               StructuredOutputPlainAgent.result()
             )

    assert {:ok, %{category: :technical, confidence: 0.64, summary: "Bug report"}} =
             Request.get_result(agent, request_id)
  end

  test "output finalization fails without repair when validation mode is error" do
    {:ok, output} = Output.new(schema: @schema, retries: 3, on_validation_error: :error)
    request_id = "req-output-error-mode"

    agent =
      StructuredOutputPlainAgent.runtime_module()
      |> new_runtime_agent()
      |> Request.start_request(request_id, "Classify this")
      |> Request.complete_request(request_id, "not structured")

    agent = Output.finalize(agent, request_id, output)

    assert {:error, %Jidoka.Error.ValidationError{} = error} = Request.get_result(agent, request_id)
    assert error.details.reason |> elem(0) == :parse
    assert get_in(agent.state, [:requests, request_id, :meta, :jidoka_output, :status]) == :error
    assert get_in(agent.state, [:requests, request_id, :meta, :jidoka_output, :attempt]) == 0
  end

  test "output repair failures record validation metadata" do
    output = StructuredOutputAgent.result()
    request_id = "req-output-repair-failure"

    agent =
      StructuredOutputAgent.runtime_module()
      |> new_runtime_agent()
      |> Request.start_request(request_id, "Classify this")
      |> Request.complete_request(request_id, "not structured")

    repair_fun = fn _output, _agent, _context, _raw, _reason ->
      {:error, Jidoka.Output.Error.output_error({:repair_failed, "still invalid"}, "not structured")}
    end

    agent = Output.finalize(agent, request_id, output, repair_fun: repair_fun)

    assert {:error, %Jidoka.Error.ValidationError{} = error} = Request.get_result(agent, request_id)
    assert error.details.reason == {:repair_failed, "still invalid"}
    assert get_in(agent.state, [:requests, request_id, :meta, :jidoka_output, :status]) == :error
    assert get_in(agent.state, [:requests, request_id, :meta, :jidoka_output, :attempt]) == 1
  end

  test "invalid repaired output fails with normalized validation metadata" do
    output = StructuredOutputAgent.result()
    request_id = "req-output-invalid-repair"

    agent =
      StructuredOutputAgent.runtime_module()
      |> new_runtime_agent()
      |> Request.start_request(request_id, "Classify this")
      |> Request.complete_request(request_id, "not structured")

    repair_fun = fn _output, _agent, _context, _raw, _reason ->
      {:ok, %{"category" => "billing", "summary" => "Missing confidence"}}
    end

    agent = Output.finalize(agent, request_id, output, repair_fun: repair_fun)

    assert {:error, %Jidoka.Error.ValidationError{} = error} = Request.get_result(agent, request_id)
    assert error.field == :output
    assert error.details.reason == {:schema, %{confidence: ["is required"]}}
    assert get_in(agent.state, [:requests, request_id, :meta, :jidoka_output, :status]) == :error
    assert get_in(agent.state, [:requests, request_id, :meta, :jidoka_output, :attempt]) == 1
  end

  test "output repair exceptions are normalized" do
    output = StructuredOutputAgent.result()
    request_id = "req-output-repair-exception"

    agent =
      StructuredOutputAgent.runtime_module()
      |> new_runtime_agent()
      |> Request.start_request(request_id, "Classify this")
      |> Request.complete_request(request_id, "not structured")

    repair_fun = fn _output, _agent, _context, _raw, _reason ->
      raise "repair exploded"
    end

    agent = Output.finalize(agent, request_id, output, repair_fun: repair_fun)

    assert {:error, %Jidoka.Error.ValidationError{} = error} = Request.get_result(agent, request_id)
    assert error.details.reason == {:repair_exception, "repair exploded"}
  end

  test "default output repair requires an agent model" do
    output = StructuredOutputAgent.result()
    request_id = "req-output-missing-model-repair"

    agent =
      StructuredOutputAgent.runtime_module()
      |> new_runtime_agent()
      |> put_in([Access.key(:state), :model], nil)
      |> Request.start_request(request_id, "Classify this")
      |> Request.complete_request(request_id, "not structured")

    agent = Output.finalize(agent, request_id, output)

    assert {:error, %Jidoka.Error.ValidationError{} = error} = Request.get_result(agent, request_id)
    assert error.details.reason == :missing_repair_model
  end

  test "output helpers expose request option and unsupported output errors" do
    {:ok, output} = Output.new(schema: @schema)
    context = Output.attach_request_option(%{}, "raw")

    assert Output.runtime_output(%{Jidoka.Output.context_key() => %{output: output}}) == output
    assert Output.runtime_output(%{Atom.to_string(Jidoka.Output.context_key()) => %{output: output}}) == output
    assert Output.runtime_output(context) == %{mode: :raw}
    assert Output.attach_request_option(%{}, :unknown) == %{}

    assert {:error, %Jidoka.Error.ValidationError{} = error} = Output.parse(output, [:not, :supported])
    assert error.details.reason == :unsupported_raw_output

    assert {:error, %Jidoka.Error.ValidationError{} = error} = Output.parse(output, ~s(["not", "an", "object"]))
    assert error.details.reason == :expected_map

    assert Jidoka.Output.Error.reason_message(RuntimeError.exception("boom")) == "boom"
  end

  test "agents without output contracts remain unchanged" do
    runtime = ChatAgent.runtime_module()
    request_id = "req-plain-output"

    agent =
      runtime
      |> new_runtime_agent()
      |> Request.start_request(request_id, "hello")
      |> Request.complete_request(request_id, "plain response")

    assert {:ok, agent, []} = runtime.on_after_cmd(agent, {:ai_react_start, %{request_id: request_id}}, [])
    assert {:ok, "plain response"} = Request.get_result(agent, request_id)
  end
end
