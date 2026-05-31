defmodule Jidoka.Agent.Dsl.Sections.Tools do
  @moduledoc false

  alias Jidoka.Agent.Dsl.{AshResource, Browser, Catalog, Tool}

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

  @spec catalog_entity() :: Spark.Dsl.Entity.t()
  def catalog_entity do
    %Spark.Dsl.Entity{
      name: :catalog,
      target: Catalog,
      args: [:name],
      describe: """
      Register a constrained operation catalog lookup source.
      """,
      schema: [
        name: [
          type: :any,
          required: true,
          doc: "Lower-snake catalog id."
        ],
        via: [
          type: :any,
          required: true,
          doc: "Runtime catalog route or module owned by the host application."
        ],
        providers: [
          type: :any,
          required: false,
          default: [],
          doc: "Optional provider/category filters for the catalog route."
        ],
        only: [
          type: :any,
          required: false,
          default: [],
          doc: "Optional operation names allowed from this catalog."
        ],
        except: [
          type: :any,
          required: false,
          default: [],
          doc: "Optional operation names excluded from this catalog."
        ],
        max_results: [
          type: :pos_integer,
          required: false,
          doc: "Optional maximum number of catalog results."
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
          doc: "Operation idempotency for the catalog lookup operation."
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
        catalog_entity()
      ]
    }
  end
end
