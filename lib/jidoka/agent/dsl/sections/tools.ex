defmodule Jidoka.Agent.Dsl.Sections.Tools do
  @moduledoc false

  alias Jidoka.Agent.Dsl.{
    AshResource,
    Handoff,
    MCPTools,
    Plugin,
    SkillPath,
    SkillRef,
    Subagent,
    Tool,
    Web,
    Workflow
  }

  @spec action_entity() :: Spark.Dsl.Entity.t()
  def action_entity do
    %Spark.Dsl.Entity{
      name: :action,
      describe: """
      Register a deterministic action module for this agent.
      """,
      target: Tool,
      args: [:module],
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
      describe: """
      Register all generated AshJido actions for an Ash resource.
      """,
      target: AshResource,
      args: [:resource],
      schema: [
        resource: [
          type: :atom,
          required: true,
          doc: "An Ash resource module extended with `AshJido`."
        ]
      ]
    }
  end

  @spec mcp_tools_entity() :: Spark.Dsl.Entity.t()
  def mcp_tools_entity do
    %Spark.Dsl.Entity{
      name: :mcp_tools,
      describe: """
      Register remote MCP tools from a configured or runtime endpoint.
      """,
      target: MCPTools,
      args: [],
      schema: [
        endpoint: [
          type: :any,
          required: true,
          doc: "The configured MCP endpoint id."
        ],
        prefix: [
          type: :string,
          required: false,
          doc: "Optional prefix to prepend to synced tool names."
        ],
        required: [
          type: :boolean,
          required: false,
          doc: "Whether MCP sync failure should fail the request instead of continuing without newly synced tools."
        ],
        transport: [
          type: :any,
          required: false,
          doc: "Optional inline MCP transport definition for runtime endpoint registration."
        ],
        client_info: [
          type: :map,
          required: false,
          doc: "Optional MCP client info when registering an inline endpoint."
        ],
        protocol_version: [
          type: :string,
          required: false,
          doc: "Optional MCP protocol version for an inline endpoint."
        ],
        capabilities: [
          type: :map,
          required: false,
          doc: "Optional MCP client capability metadata for an inline endpoint."
        ],
        timeouts: [
          type: :map,
          required: false,
          doc: "Optional MCP timeout settings for an inline endpoint."
        ]
      ]
    }
  end

  @spec skill_ref_entity() :: Spark.Dsl.Entity.t()
  def skill_ref_entity do
    %Spark.Dsl.Entity{
      name: :skill,
      describe: """
      Register a Jido.AI skill module or runtime skill name for this agent.
      """,
      target: SkillRef,
      args: [:skill],
      schema: [
        skill: [
          type: :any,
          required: true,
          doc: "A Jido.AI skill module or runtime skill name."
        ]
      ]
    }
  end

  @spec skill_path_entity() :: Spark.Dsl.Entity.t()
  def skill_path_entity do
    %Spark.Dsl.Entity{
      name: :load_path,
      describe: """
      Load SKILL.md files from a directory or file path at runtime.
      """,
      target: SkillPath,
      args: [:path],
      schema: [
        path: [
          type: :string,
          required: true,
          doc: "A directory or SKILL.md file path."
        ]
      ]
    }
  end

  @spec plugin_entity() :: Spark.Dsl.Entity.t()
  def plugin_entity do
    %Spark.Dsl.Entity{
      name: :plugin,
      describe: """
      Register a Jidoka plugin module for this agent.
      """,
      target: Plugin,
      args: [:module],
      schema: [
        module: [
          type: :atom,
          required: true,
          doc: "A module defined with `use Jidoka.Plugin`."
        ]
      ]
    }
  end

  @spec web_entity() :: Spark.Dsl.Entity.t()
  def web_entity do
    %Spark.Dsl.Entity{
      name: :web,
      describe: """
      Register low-risk web browsing tools for this agent.
      """,
      target: Web,
      args: [:mode],
      schema: [
        mode: [
          type: :any,
          required: true,
          doc: "Web tool mode. Supports :search or :read_only."
        ]
      ]
    }
  end

  @spec subagent_entity() :: Spark.Dsl.Entity.t()
  def subagent_entity do
    %Spark.Dsl.Entity{
      name: :subagent,
      describe: """
      Register a bounded-delegation specialist for this agent.
      """,
      target: Subagent,
      args: [:agent],
      schema: [
        agent: [
          type: :atom,
          required: true,
          doc: "A Jidoka-compatible agent module that can handle one delegated specialist task."
        ],
        as: [
          type: :string,
          required: false,
          doc: "Optional published tool name override for this subagent."
        ],
        description: [
          type: :string,
          required: false,
          doc: "Optional tool description override for this subagent."
        ],
        target: [
          type: :any,
          required: false,
          default: :ephemeral,
          doc: """
          Delegation mode for this subagent. Supports :ephemeral,
          {:peer, "id"}, and {:peer, {:context, key}}.
          """
        ],
        timeout: [
          type: :any,
          required: false,
          default: 30_000,
          doc: "Bounded child-task timeout in milliseconds."
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
          default: :text,
          doc: "Parent-visible result shape: :text or :structured."
        ]
      ]
    }
  end

  @spec workflow_entity() :: Spark.Dsl.Entity.t()
  def workflow_entity do
    %Spark.Dsl.Entity{
      name: :workflow,
      describe: """
      Expose a deterministic Jidoka workflow as an agent operation.
      """,
      target: Workflow,
      args: [:workflow],
      schema: [
        workflow: [
          type: :atom,
          required: true,
          doc: "A module defined with `use Jidoka.Workflow`."
        ],
        as: [
          type: :any,
          required: false,
          doc: "Optional published operation name override for this workflow."
        ],
        description: [
          type: :string,
          required: false,
          doc: "Optional operation description override for this workflow."
        ],
        timeout: [
          type: :any,
          required: false,
          default: 30_000,
          doc: "Workflow execution timeout in milliseconds."
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
        ]
      ]
    }
  end

  @spec handoff_entity() :: Spark.Dsl.Entity.t()
  def handoff_entity do
    %Spark.Dsl.Entity{
      name: :handoff,
      describe: """
      Register a Jidoka handoff target that can become conversation owner.
      """,
      target: Handoff,
      args: [:agent],
      schema: [
        agent: [
          type: :atom,
          required: true,
          doc: "A Jidoka-compatible agent module that can receive future turns for a conversation."
        ],
        as: [
          type: :any,
          required: false,
          doc: "Optional published handoff tool name."
        ],
        description: [
          type: :string,
          required: false,
          doc: "Optional handoff tool description."
        ],
        target: [
          type: :any,
          required: false,
          default: :auto,
          doc: "Handoff target: :auto, {:peer, \"id\"}, or {:peer, {:context, key}}."
        ],
        forward_context: [
          type: :any,
          required: false,
          default: :public,
          doc: "Context forwarding policy: :public, :none, {:only, keys}, or {:except, keys}."
        ]
      ]
    }
  end

  @spec section() :: Spark.Dsl.Section.t()
  def section do
    %Spark.Dsl.Section{
      name: :tools,
      describe: """
      Register operations and integrations available to this agent.
      """,
      entities: [
        action_entity(),
        ash_resource_entity(),
        mcp_tools_entity(),
        skill_ref_entity(),
        skill_path_entity(),
        plugin_entity(),
        web_entity(),
        subagent_entity(),
        workflow_entity(),
        handoff_entity()
      ]
    }
  end
end
