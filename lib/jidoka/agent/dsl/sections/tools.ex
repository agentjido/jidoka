defmodule Jidoka.Agent.Dsl.Sections.Tools do
  @moduledoc false

  alias Jidoka.Agent.Dsl.{
    AshResource,
    Browser,
    Handoff,
    MCPTools,
    SkillPath,
    SkillRef,
    Subagent,
    Tool,
    Workflow
  }

  @spec action_entity() :: Spark.Dsl.Entity.t()
  def action_entity do
    %Spark.Dsl.Entity{
      name: :action,
      target: Tool,
      args: [:module],
      describe: """
      Register a deterministic action module for this agent.
      """,
      schema: [
        module: [
          type: :atom,
          required: true,
          doc: "A module defined with `use Jidoka.Action` or a compatible Jido action module."
        ]
      ]
    }
  end

  @spec ash_resource_entity() :: Spark.Dsl.Entity.t()
  def ash_resource_entity do
    %Spark.Dsl.Entity{
      name: :ash_resource,
      target: AshResource,
      args: [:resource],
      describe: """
      Register an Ash resource as a source of model-callable operations.
      """,
      schema: [
        resource: [
          type: :atom,
          required: true,
          doc: "An Ash resource module, typically extended with AshJido."
        ],
        actions: [
          type: :any,
          required: false,
          default: [],
          doc: "Optional generated AshJido action names to expose."
        ],
        description: [
          type: :string,
          required: false,
          doc: "Optional description override for generated AshJido operation specs."
        ],
        idempotency: [
          type: :any,
          required: false,
          default: :idempotent,
          doc: "Operation idempotency override for generated AshJido operation specs."
        ],
        metadata: [
          type: :map,
          required: false,
          default: %{},
          doc: "Optional metadata merged into generated operation specs."
        ]
      ]
    }
  end

  @spec browser_entity() :: Spark.Dsl.Entity.t()
  def browser_entity do
    %Spark.Dsl.Entity{
      name: :browser,
      target: Browser,
      args: [:name],
      describe: """
      Register a constrained browser operation source.
      """,
      schema: [
        name: [
          type: :any,
          required: true,
          doc: "Lower-snake browser capability id, such as :docs or :public_web."
        ],
        mode: [
          type: :any,
          required: false,
          default: :read_only,
          doc: "Browser mode, such as :read_only or :search."
        ],
        allow: [
          type: :any,
          required: false,
          default: [],
          doc: "Optional allowlist of hosts or URLs controlled by the runtime implementation."
        ],
        description: [
          type: :string,
          required: false,
          doc: "Optional operation description override."
        ],
        idempotency: [
          type: :any,
          required: false,
          default: :idempotent,
          doc: "Operation idempotency for the browser operation."
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

  @spec mcp_tools_entity() :: Spark.Dsl.Entity.t()
  def mcp_tools_entity do
    %Spark.Dsl.Entity{
      name: :mcp_tools,
      target: MCPTools,
      args: [],
      describe: """
      Register tools exposed by a configured MCP endpoint.
      """,
      schema: [
        endpoint: [
          type: :any,
          required: true,
          doc: "Configured MCP endpoint id."
        ],
        prefix: [
          type: :string,
          required: false,
          doc: "Optional operation-name prefix for discovered MCP tools."
        ],
        tools: [
          type: :any,
          required: false,
          default: [],
          doc: "Optional static MCP tool metadata when discovery is not available at compile time."
        ],
        required: [
          type: :boolean,
          required: false,
          default: false,
          doc: "Whether discovery failure should fail spec compilation."
        ],
        transport: [
          type: :any,
          required: false,
          doc: "Optional inline MCP transport definition for runtime endpoint registration."
        ],
        client_info: [
          type: :map,
          required: false,
          doc: "Optional MCP client info for inline endpoint registration."
        ],
        protocol_version: [
          type: :string,
          required: false,
          doc: "Optional MCP protocol version for inline endpoint registration."
        ],
        capabilities: [
          type: :map,
          required: false,
          default: %{},
          doc: "Optional MCP client capability metadata for inline endpoint registration."
        ],
        timeouts: [
          type: :map,
          required: false,
          default: %{},
          doc: "Optional MCP timeout metadata for inline endpoint registration."
        ],
        timeout: [
          type: :pos_integer,
          required: false,
          doc: "Optional MCP request timeout in milliseconds."
        ],
        description: [
          type: :string,
          required: false,
          doc: "Optional description override applied to generated operations."
        ],
        idempotency: [
          type: :any,
          required: false,
          default: :idempotent,
          doc: "Operation idempotency for generated MCP operations."
        ],
        metadata: [
          type: :map,
          required: false,
          default: %{},
          doc: "Optional metadata merged into generated operation specs."
        ]
      ]
    }
  end

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

  @spec section() :: Spark.Dsl.Section.t()
  def section do
    %Spark.Dsl.Section{
      name: :tools,
      describe: """
      Register model-callable operations and operation sources.
      """,
      entities: [
        action_entity(),
        ash_resource_entity(),
        browser_entity(),
        mcp_tools_entity(),
        skill_ref_entity(),
        skill_path_entity(),
        subagent_entity(),
        handoff_entity(),
        workflow_entity()
      ]
    }
  end
end
