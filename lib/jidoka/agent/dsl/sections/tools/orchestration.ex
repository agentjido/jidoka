defmodule Jidoka.Agent.Dsl.Sections.Tools.Orchestration do
  @moduledoc false

  alias Jidoka.Agent.Dsl.{Handoff, SkillPath, SkillRef, Subagent, Workflow}

  @spec skill_ref_entity() :: Spark.Dsl.Entity.t()
  def skill_ref_entity do
    %Spark.Dsl.Entity{
      name: :skill,
      target: SkillRef,
      args: [:skill],
      describe: """
      Register a Jido.AI skill module or runtime-loaded skill name.
      """,
      schema: [
        skill: [
          type: :any,
          required: true,
          doc: "A module defined with `use Jido.AI.Skill` or a runtime skill name."
        ]
      ]
    }
  end

  @spec skill_path_entity() :: Spark.Dsl.Entity.t()
  def skill_path_entity do
    %Spark.Dsl.Entity{
      name: :load_path,
      target: SkillPath,
      args: [:path],
      describe: """
      Load `SKILL.md` files for runtime skill references.
      """,
      schema: [
        path: [
          type: :string,
          required: true,
          doc: "A directory containing SKILL.md files or a specific SKILL.md path."
        ]
      ]
    }
  end

  @spec subagent_entity() :: Spark.Dsl.Entity.t()
  def subagent_entity do
    %Spark.Dsl.Entity{
      name: :subagent,
      target: Subagent,
      args: [:agent],
      describe: """
      Register a bounded delegation specialist as a model-callable operation.
      """,
      schema: [
        agent: [
          type: :atom,
          required: true,
          doc: "A module using `Jidoka.Agent`."
        ],
        as: [
          type: :any,
          required: false,
          doc: "Optional published operation name."
        ],
        description: [
          type: :string,
          required: false,
          doc: "Optional operation description override."
        ],
        timeout: [
          type: :pos_integer,
          required: false,
          default: 30_000,
          doc: "Bounded child-agent timeout in milliseconds."
        ],
        forward_context: [
          type: :any,
          required: false,
          default: :public,
          doc: "Context forwarding policy: :public, :none, {:only, keys}, or {:except, keys}."
        ],
        result: [
          type: :any,
          required: false,
          default: :structured,
          doc: "Parent-visible result shape: :text or :structured."
        ],
        metadata: [
          type: :map,
          required: false,
          default: %{},
          doc: "Optional metadata merged into the operation spec."
        ]
      ]
    }
  end

  @spec handoff_entity() :: Spark.Dsl.Entity.t()
  def handoff_entity do
    %Spark.Dsl.Entity{
      name: :handoff,
      target: Handoff,
      args: [:agent],
      describe: """
      Register a conversation ownership transfer as a model-callable operation.
      """,
      schema: [
        agent: [
          type: :atom,
          required: true,
          doc: "A module using `Jidoka.Agent` that should own future turns."
        ],
        as: [
          type: :any,
          required: false,
          doc: "Optional published operation name."
        ],
        description: [
          type: :string,
          required: false,
          doc: "Optional operation description override."
        ],
        target: [
          type: :any,
          required: false,
          default: :auto,
          doc: "Target process id policy: :auto, {:peer, id}, or {:peer, {:context, key}}."
        ],
        forward_context: [
          type: :any,
          required: false,
          default: :public,
          doc: "Context forwarding policy: :public, :none, {:only, keys}, or {:except, keys}."
        ],
        metadata: [
          type: :map,
          required: false,
          default: %{},
          doc: "Optional metadata merged into the operation spec."
        ]
      ]
    }
  end

  @spec workflow_entity() :: Spark.Dsl.Entity.t()
  def workflow_entity do
    %Spark.Dsl.Entity{
      name: :workflow,
      target: Workflow,
      args: [:workflow],
      describe: """
      Register a deterministic workflow as a model-callable operation.
      """,
      schema: [
        workflow: [
          type: :atom,
          required: true,
          doc: "A module using `Jidoka.Workflow`."
        ],
        as: [
          type: :any,
          required: false,
          doc: "Optional published operation name."
        ],
        description: [
          type: :string,
          required: false,
          doc: "Optional operation description override."
        ],
        timeout: [
          type: :pos_integer,
          required: false,
          default: 30_000,
          doc: "Workflow timeout in milliseconds."
        ],
        async: [
          type: :boolean,
          required: false,
          default: false,
          doc: "Run independent workflow steps concurrently."
        ],
        max_concurrency: [
          type: :pos_integer,
          required: false,
          doc: "Maximum concurrent workflow steps when async is enabled."
        ],
        forward_context: [
          type: :any,
          required: false,
          default: :public,
          doc: "Context forwarding policy: :public, :none, {:only, keys}, or {:except, keys}."
        ],
        result: [
          type: :any,
          required: false,
          default: :output,
          doc: "Parent-visible result shape: :output or :structured."
        ],
        idempotency: [
          type: :any,
          required: false,
          default: :idempotent,
          doc: "Operation idempotency policy for the workflow operation."
        ],
        metadata: [
          type: :map,
          required: false,
          default: %{},
          doc: "Optional metadata merged into the operation spec."
        ]
      ]
    }
  end
end
