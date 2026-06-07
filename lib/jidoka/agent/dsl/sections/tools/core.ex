defmodule Jidoka.Agent.Dsl.Sections.Tools.Core do
  @moduledoc false

  alias Jidoka.Agent.Dsl.{AshResource, Browser, Catalog, MCPTools, Tool}

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
        ],
        description: [
          type: :string,
          required: false,
          doc: "Optional operation description override."
        ],
        idempotency: [
          type: :any,
          required: false,
          doc: "Optional operation idempotency override."
        ],
        approval: [
          type: :any,
          required: false,
          doc:
            "Approval policy: true, :unsafe_once, or keyword options such as only:, except:, reason:, message:, ttl_ms:."
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
        approval: [
          type: :any,
          required: false,
          doc: "Approval policy applied to generated operations."
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
        approval: [
          type: :any,
          required: false,
          doc: "Approval policy applied to generated browser operations."
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
        discover: [
          type: :boolean,
          required: false,
          default: false,
          doc: "Whether spec compilation may dynamically discover tools from the MCP endpoint."
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
        approval: [
          type: :any,
          required: false,
          doc: "Approval policy applied to generated MCP operations."
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

  @spec catalog_entity() :: Spark.Dsl.Entity.t()
  def catalog_entity do
    %Spark.Dsl.Entity{
      name: :catalog,
      target: Catalog,
      args: [:catalog],
      describe: """
      Register a Jido Action Catalog as a governed scripted operation source.
      """,
      schema: [
        catalog: [
          type: :atom,
          required: true,
          doc: "A module exposing `catalog/0` that returns a `Jido.Action.Catalog`."
        ],
        prefix: [
          type: :any,
          required: false,
          default: "catalog_",
          doc: "Generated operation prefix. Defaults to `catalog_`."
        ],
        description: [
          type: :string,
          required: false,
          doc: "Optional description override applied to generated operations."
        ],
        timeout: [
          type: :pos_integer,
          required: false,
          default: 1_500,
          doc: "Lua workflow timeout in milliseconds."
        ],
        max_calls: [
          type: :pos_integer,
          required: false,
          default: 12,
          doc: "Maximum hidden catalog action calls per script."
        ],
        max_parallel_calls: [
          type: :pos_integer,
          required: false,
          default: 8,
          doc: "Maximum parallel hidden catalog action calls per script."
        ],
        require_read_only?: [
          type: :boolean,
          required: false,
          default: true,
          doc: "Whether only read-only catalog entries may be executed."
        ],
        result: [
          type: :any,
          required: false,
          default: :structured,
          doc: "Parent-visible result shape. Currently `:structured`."
        ],
        idempotency: [
          type: :any,
          required: false,
          default: :idempotent,
          doc: "Operation idempotency policy for generated catalog operations."
        ],
        approval: [
          type: :any,
          required: false,
          doc: "Approval policy applied to generated catalog operations."
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
end
