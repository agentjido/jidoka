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

  test "skill actions execute through the normal operation effect path" do
    llm = fn _intent, %Effect.Journal{} = journal ->
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
end
