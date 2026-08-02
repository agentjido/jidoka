defmodule Jidoka.Parity.PortableAgentAuthoringTest do
  use Jidoka.ParityCase, parity: :portable_agent_authoring

  alias Jidoka.Agent.Spec
  alias Jidoka.Effect
  alias Jidoka.Runtime.Controls.OperationContext
  alias Jidoka.Runtime.JidoActions
  alias Jidoka.Turn

  defmodule LookupAction do
    @moduledoc false

    use Jidoka.Action,
      name: "lookup_policy",
      description: "Looks up one tenant policy.",
      schema: Zoi.object(%{query: Zoi.string()})

    @impl true
    def run(params, context) do
      observer = Jidoka.Context.get_runtime(context, :observer)

      send(observer, {
        :action_context,
        %{tenant_id: Jidoka.Context.get(context, :tenant_id)},
        Jidoka.Context.get_runtime(context, :credential_ref)
      })

      {:ok,
       %{
         "query" => Jidoka.Schema.get_key(params, :query),
         "tenant_id" => Jidoka.Context.get(context, :tenant_id)
       }}
    end
  end

  defmodule ContextControl do
    @moduledoc false

    use Jidoka.Control, name: "authoring_context_control"

    @impl true
    def call(%OperationContext{ctx: context}) do
      observer = Jidoka.Context.get_runtime(context, :observer)

      send(observer, {
        :control_context,
        Jidoka.Context.data(context),
        Jidoka.Context.get_runtime(context, :credential_ref)
      })

      :allow
    end

    def call(_context), do: :allow
  end

  defmodule DslAgent do
    @moduledoc false

    use Jidoka.Agent

    @context_schema Zoi.object(%{tenant_id: Zoi.string()})
    @result_schema Zoi.object(%{answer: Zoi.string()})

    def context_schema, do: @context_schema
    def result_schema, do: @result_schema

    agent :portable_authoring_agent do
      model "test:portable-model"
      generation %{temperature: 0.0, max_tokens: 32}
      instructions "Use lookup_policy before answering."
      context @context_schema
      result schema: @result_schema, max_repairs: 1
      memory scope: :session, max_entries: 3
    end

    tools do
      action LookupAction
    end

    controls do
      max_turns 3
      timeout 1_000

      operation ContextControl,
        when: [kind: :action, name: "lookup_policy"]
    end
  end

  @tag :a01
  test "the DSL and direct constructor compile to the same public agent contract" do
    direct =
      Jidoka.agent!(
        id: "portable_authoring_agent",
        model: "test:portable-model",
        generation: %{temperature: 0.0, max_tokens: 32},
        instructions: "Use lookup_policy before answering.",
        context_schema: DslAgent.context_schema(),
        result: %{schema: DslAgent.result_schema(), max_repairs: 1},
        memory: %{scope: :session, max_entries: 3},
        operations: JidoActions.operations_from_actions([LookupAction]),
        controls: %{
          max_turns: 3,
          timeout_ms: 1_000,
          operations: [
            %{
              control: ContextControl,
              match: %{kind: :action, name: "lookup_policy"}
            }
          ]
        }
      )

    assert semantic_projection(DslAgent.spec()) == semantic_projection(direct)
    assert {:ok, %Spec{}} = Jidoka.agent(Map.from_struct(direct))
  end

  @tag :a02
  test "JSON and YAML round trips preserve the portable projected contract" do
    for format <- [:json, :yaml] do
      assert {:ok, document} =
               Jidoka.export(DslAgent,
                 format: format,
                 context_schema_ref: "tenant_context",
                 result_schema_ref: "answer_result"
               )

      assert {:ok, %Spec{} = imported} =
               Jidoka.import(document,
                 format: format,
                 controls: %{"authoring_context_control" => ContextControl},
                 context_schemas: %{"tenant_context" => DslAgent.context_schema()},
                 result_schemas: %{"answer_result" => DslAgent.result_schema()}
               )

      assert semantic_projection(imported) == semantic_projection(DslAgent.spec())
    end
  end

  @tag :a03
  @tag :a04
  test "dynamic instructions see public data while controls and actions receive trusted runtime data" do
    test_pid = self()

    instructions = fn base, context ->
      send(test_pid, {:instruction_context, context})
      "#{base} Tenant: #{context.data.tenant_id}."
    end

    llm = fn intent, %Effect.Journal{} = journal, _context ->
      if operation_result_count(journal) == 0 do
        {:ok,
         %{
           type: :operation,
           name: "lookup_policy",
           arguments: %{"query" => "refund"}
         }}
      else
        send(test_pid, {:resolved_prompt, intent.payload.prompt})

        {:ok,
         %{
           type: :final,
           content: "Policy ready.",
           result: %{"answer" => "Policy ready."}
         }}
      end
    end

    assert {:ok, %Turn.Result{value: %{answer: "Policy ready."}}} =
             DslAgent.run_turn("Find the refund policy",
               context: %{tenant_id: "tenant_1"},
               instructions: instructions,
               llm: llm,
               operation_context: %{
                 credential_ref: "credential:private",
                 observer: test_pid
               }
             )

    assert_receive {:instruction_context, instruction_context}
    assert instruction_context.data == %{tenant_id: "tenant_1"}
    assert instruction_context.runtime == %{}

    assert_receive {:control_context, %{tenant_id: "tenant_1"}, "credential:private"}
    assert_receive {:action_context, %{tenant_id: "tenant_1"}, "credential:private"}
    assert_receive {:resolved_prompt, prompt}
    assert hd(prompt.messages).content =~ "Tenant: tenant_1."

    never_call = fn _intent, _journal, _context ->
      flunk("invalid typed context must stop before the model runs")
    end

    assert {:error, error} =
             DslAgent.run_turn("Reject this", context: %{tenant_id: 123}, llm: never_call)

    assert Jidoka.Error.category(error) == :validation
  end

  defp semantic_projection(spec) do
    spec
    |> Jidoka.project()
    |> Map.delete(:metadata)
    |> update_in([:result], fn
      nil -> nil
      result -> Map.put(result, :metadata, %{})
    end)
  end

  defp operation_result_count(journal) do
    Enum.count(journal.results, fn {_id, result} -> result.kind == :operation end)
  end
end
