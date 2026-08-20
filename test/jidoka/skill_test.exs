defmodule Jidoka.SkillTest do
  use ExUnit.Case, async: true

  alias Jidoka.Effect
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  defmodule PolicyLookupAction do
    @moduledoc false

    use Jidoka.Action,
      name: "skill_policy_lookup",
      description: "Looks up a support policy by topic.",
      schema:
        Zoi.object(%{
          topic: Zoi.string()
        })

    @impl true
    def run(params, _context) do
      topic = Map.get(params, :topic) || Map.get(params, "topic")
      {:ok, %{topic: topic, policy: "Offer a concise answer and cite the support policy."}}
    end
  end

  defmodule SupportPolicySkill do
    @moduledoc false

    use Jido.AI.Skill,
      name: "support-policy",
      description: "Adds support policy lookup behavior.",
      allowed_tools: ["skill_policy_lookup"],
      actions: [PolicyLookupAction],
      body: """
      # Support Policy

      Use skill_policy_lookup before answering policy questions.
      """
  end

  defmodule EscalationLookupAction do
    @moduledoc false

    use Jidoka.Action,
      name: "skill_escalation_lookup",
      description: "Looks up an escalation policy by topic.",
      schema:
        Zoi.object(%{
          topic: Zoi.string()
        })

    @impl true
    def run(params, _context) do
      topic = Map.get(params, :topic) || Map.get(params, "topic")
      {:ok, %{topic: topic, policy: "Escalate urgent enterprise requests to the duty manager."}}
    end
  end

  defmodule EscalationPolicySkill do
    @moduledoc false

    use Jido.AI.Skill,
      name: "escalation-policy",
      description: "Adds escalation policy lookup behavior.",
      allowed_tools: ["skill_escalation_lookup"],
      actions: [EscalationLookupAction],
      body: """
      # Escalation Policy

      Use skill_escalation_lookup before answering escalation questions.
      """
  end

  defmodule ChangingSkill do
    @moduledoc false

    alias Jido.AI.Skill.Spec

    def manifest do
      version = Process.get({__MODULE__, :resolution_count}, 0) + 1
      Process.put({__MODULE__, :resolution_count}, version)

      {action, allowed_tool} =
        case version do
          1 -> {PolicyLookupAction, "skill_policy_lookup"}
          _version -> {EscalationLookupAction, "skill_escalation_lookup"}
        end

      %Spec{
        name: "changing-skill-#{version}",
        description: "Skill snapshot #{version}.",
        allowed_tools: [allowed_tool],
        actions: [action],
        body_ref: {:inline, "Use snapshot #{version}."},
        source: {:module, __MODULE__}
      }
    end

    def body, do: "This function must not be read during resolution."
    def actions, do: []
  end

  defmodule InvalidSkillAction do
    @moduledoc false
  end

  defmodule InvalidActionSkill do
    @moduledoc false

    use Jido.AI.Skill,
      name: "invalid-action-skill",
      description: "Publishes an invalid action for resolver tests.",
      actions: [InvalidSkillAction],
      body: "Invalid action test."
  end

  defmodule SkillAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :skill_agent do
      model %{provider: :test, id: "model"}
      instructions "Answer support questions with available capabilities."
    end

    tools do
      skill SupportPolicySkill
    end
  end

  defmodule MultiSkillAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :multi_skill_agent do
      model %{provider: :test, id: "model"}
      instructions "Answer support questions with available capabilities."
    end

    tools do
      skill SupportPolicySkill
      skill EscalationPolicySkill
    end
  end

  defmodule ChangingSkillAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :changing_skill_agent do
      model %{provider: :test, id: "model"}
      instructions "Use the stable skill snapshot."
    end

    tools do
      skill ChangingSkill
    end
  end

  test "skills contribute prompt instructions and action-backed operations" do
    spec = SkillAgent.spec()

    assert spec.instructions =~ "support-policy"
    assert spec.instructions =~ "Use skill_policy_lookup before answering policy questions."

    assert [
             %Jidoka.Agent.Spec.Operation{
               name: "skill_policy_lookup",
               metadata: %{"source" => "skill", "kind" => "skill", "skill" => "support-policy"}
             }
           ] = spec.operations

    assert [%{"source" => "skill", "name" => "support-policy"}] =
             spec.metadata["tool_sources"]
  end

  test "multiple skills contribute one metadata entry each" do
    assert [
             %{"source" => "skill", "name" => "support-policy"},
             %{"source" => "skill", "name" => "escalation-policy"}
           ] = MultiSkillAgent.spec().metadata["tool_sources"]
  end

  test "skill actions execute through the normal operation effect path" do
    llm = fn _intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "skill_policy_lookup",
             arguments: %{"topic" => "refunds"}
           }}

        1 ->
          {:ok, %{type: :final, content: "Refunds should follow the support policy."}}
      end
    end

    assert {:ok, %Turn.Result{} = result} =
             SkillAgent.run_turn("What is the refund policy?", llm: llm)

    assert result.content == "Refunds should follow the support policy."

    assert [
             %Effect.OperationResult{
               operation: "skill_policy_lookup",
               output: %{"policy" => "Offer a concise answer and cite the support policy."}
             }
           ] = result.agent_state.operation_results
  end

  test "invalid skill refs are rejected during validation" do
    assert {:error, message} = Jidoka.Skill.validate_ref("Bad Skill")
    assert message =~ "invalid skill name"

    assert {:error, "skill names must not be empty"} = Jidoka.Skill.validate_ref("   ")

    assert {:error, message} = Jidoka.Skill.validate_ref(%{})
    assert message =~ "skill entries must be modules or skill-name strings"

    assert {:error, "skill load paths must not be empty"} = Jidoka.Skill.validate_load_path("")

    assert {:error, message} = Jidoka.Skill.validate_load_path(:not_a_path)
    assert message =~ "skill load paths must be strings"

    assert {:error, message} = Jidoka.Skill.validate_ref(String)
    assert message =~ "manifest/0, body/0, and actions/0"
  end

  test "skill helpers resolve prompts, metadata, actions, and load paths explicitly" do
    assert [PolicyLookupAction] = Jidoka.Skill.action_modules([SupportPolicySkill])

    assert {:ok, prompt} = Jidoka.Skill.prompt([SupportPolicySkill])
    assert prompt =~ "Support Policy"

    assert {:ok, [%{"name" => "support-policy", "actions" => actions}]} =
             Jidoka.Skill.metadata([SupportPolicySkill])

    assert inspect(PolicyLookupAction) in actions

    base = File.cwd!()
    skills_path = Path.expand("skills", base)
    more_skills_path = Path.expand("more_skills", base)

    assert [^skills_path, ^more_skills_path] =
             Jidoka.Skill.normalize_load_paths(["skills", "more_skills", "skills"], base)

    assert {:error, {:invalid_skill, "missing-skill", _reason}} =
             Jidoka.Skill.prompt(["missing-skill"])
  end

  test "one tool compilation derives all skill views from one resolution" do
    Process.put({ChangingSkill, :resolution_count}, 0)

    compiled = Jidoka.Agent.ToolSources.compile!(ChangingSkillAgent)

    assert Process.get({ChangingSkill, :resolution_count}) == 1
    assert compiled.actions == [PolicyLookupAction]
    assert [%{name: "skill_policy_lookup"}] = compiled.operations
    assert compiled.skill_prompt =~ "changing-skill-1"
    assert compiled.skill_prompt =~ "Use snapshot 1."

    assert [%{"name" => "changing-skill-1", "actions" => [action]}] = compiled.metadata
    assert action == inspect(PolicyLookupAction)
  end

  test "one direct DSL turn resolves its tool sources once" do
    Process.put({ChangingSkill, :resolution_count}, 0)

    llm = fn _intent, %Effect.Journal{}, _ctx ->
      {:ok, %{type: :final, content: "One stable source snapshot."}}
    end

    assert {:ok, %Turn.Result{content: "One stable source snapshot."}} =
             ChangingSkillAgent.run_turn("Use one source snapshot.", llm: llm)

    assert Process.get({ChangingSkill, :resolution_count}) == 1
  end

  test "resume rejects a changed DSL operation-source contract" do
    Process.put({ChangingSkill, :resolution_count}, 0)

    llm = fn _intent, %Effect.Journal{}, _ctx ->
      {:ok, %{type: :final, content: "This result must not run after drift."}}
    end

    assert {:hibernate, snapshot} =
             ChangingSkillAgent.run_turn("Pause before the model effect.",
               llm: llm,
               checkpoint: :before_each_effect
             )

    assert Process.get({ChangingSkill, :resolution_count}) == 1

    assert {:error, {:dsl_operation_source_digest_mismatch, expected, actual}} =
             Jidoka.Harness.resume(snapshot, llm: llm)

    assert is_binary(expected)
    assert is_binary(actual)
    assert expected != actual
    assert Process.get({ChangingSkill, :resolution_count}) == 2
  end

  test "a previously compiled DSL spec rejects changed source handlers before a turn" do
    Process.put({ChangingSkill, :resolution_count}, 0)
    spec = ChangingSkillAgent.spec()

    llm = fn _intent, %Effect.Journal{}, _ctx ->
      flunk("source drift must fail before the model capability runs")
    end

    assert {:error, {:dsl_operation_source_digest_mismatch, expected, actual}} =
             Jidoka.Turn.Execution.run(spec, "Reject source drift.", llm: llm)

    assert expected != actual
    assert Process.get({ChangingSkill, :resolution_count}) == 2
  end

  test "a resolved skill value preserves action and prompt order" do
    assert {:ok, resolution} =
             Jidoka.Skill.resolve([SupportPolicySkill, EscalationPolicySkill])

    assert Jidoka.Skill.action_modules(resolution) == [
             PolicyLookupAction,
             EscalationLookupAction
           ]

    assert {:ok, prompt} = Jidoka.Skill.prompt(resolution)
    assert position(prompt, "support-policy") < position(prompt, "escalation-policy")
  end

  test "an invalid skill action returns one typed resolution error" do
    assert {:error, {:invalid_skill_action, InvalidActionSkill, InvalidSkillAction, :missing_to_tool}} =
             Jidoka.Skill.resolve([InvalidActionSkill])
  end

  defp position(text, value) do
    {position, _length} = :binary.match(text, value)
    position
  end
end
