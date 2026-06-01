defmodule Jidoka.LiveReqLLMTest do
  use ExUnit.Case, async: false

  @moduletag :live
  @moduletag timeout: 120_000

  @live_enabled? not is_nil(System.get_env("OPENAI_API_KEY") || System.get_env("ANTHROPIC_API_KEY"))

  if @live_enabled? do
    alias Jidoka.Effect
    alias Jidoka.Turn

    defmodule LocalTime do
      use Jidoka.Action,
        name: "local_time",
        description: "Returns the local time for a city plus a canary that must appear in the final answer.",
        schema:
          Zoi.object(%{
            city: Zoi.string() |> Zoi.default("Chicago")
          })

      @impl true
      def run(params, _context) do
        city = Map.get(params, :city) || Map.get(params, "city") || "Chicago"

        {:ok,
         %{
           city: city,
           timezone: "America/Chicago",
           time: "09:30",
           canary: "jidoka_live_canary_0930"
         }}
      end
    end

    defmodule RequireLocalTimeApproval do
      use Jidoka.Control, name: "require_local_time_approval"

      @impl true
      def call(_operation), do: :cont
    end

    defmodule TimeAgent do
      use Jidoka.Agent

      @live_model Jidoka.Config.model_ref(Jidoka.Config.default_model())

      agent :live_time_agent do
        model @live_model

        instructions """
        You are a Jidoka live integration test agent.
        You must call local_time exactly once before producing a final answer.
        Your final answer must include the exact canary value returned by local_time.
        """
      end

      tools do
        action Jidoka.LiveReqLLMTest.LocalTime
      end

      controls do
        operation Jidoka.LiveReqLLMTest.RequireLocalTimeApproval,
          when: [kind: :action, name: :local_time]
      end
    end

    test "runs a real DSL-defined LLM operation loop through ReqLLM and Jido actions" do
      assert [
               %Jidoka.Agent.Spec.Controls.Operation{
                 control: RequireLocalTimeApproval,
                 match: %{kind: :action, name: "local_time"}
               }
             ] = TimeAgent.spec().controls.operations

      assert {:ok, %Turn.Result{} = result} =
               TimeAgent.run_turn("What time is it in Chicago? Use local_time.")

      assert result.content =~ "09:30"

      assert [%Effect.OperationResult{operation: "local_time"} = operation_result] =
               result.agent_state.operation_results

      assert Map.get(operation_result.output, "canary") == "jidoka_live_canary_0930"

      assert Enum.count(result.journal.results) == 3
    end
  else
    @tag :skip
    test "runs a real DSL-defined LLM operation loop through ReqLLM and Jido actions" do
      :ok
    end
  end
end
