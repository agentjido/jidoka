defmodule Jidoka.Agent.Dsl.Sections.Agent do
  @moduledoc false

  @spec agent_entity() :: Spark.Dsl.Entity.t()
  def agent_entity do
    %Spark.Dsl.Entity{
      name: :agent,
      target: Jidoka.Agent.Dsl.Agent,
      args: [:id],
      describe: """
      Configure the immutable Jidoka agent contract.
      """,
      schema: [
        id: [
          type: :any,
          required: true,
          doc: "The stable public agent id. Must be lower snake case."
        ],
        model: [
          type: :any,
          required: false,
          doc:
            "Optional ReqLLM model input, such as `openai:gpt-4o-mini` or an inline LLMDB model map."
        ],
        generation: [
          type: :any,
          required: false,
          doc: "Optional provider-facing generation defaults."
        ],
        instructions: [
          type: :string,
          required: false,
          doc: "Optional default instructions used for this agent."
        ],
        description: [
          type: :string,
          required: false,
          doc: "Optional human-readable description for inspection."
        ],
        context: [
          type: :any,
          required: false,
          doc: "Optional Zoi schema for runtime context."
        ],
        result: [
          type: :any,
          required: false,
          doc:
            "Optional Zoi schema or `Jidoka.Agent.Spec.Result` data for structured turn results."
        ],
        memory: [
          type: :any,
          required: false,
          doc: "Optional memory policy data, `true`, or `false`."
        ]
      ]
    }
  end

  @spec section() :: Spark.Dsl.Section.t()
  def section do
    %Spark.Dsl.Section{
      name: :jidoka,
      top_level?: true,
      singleton_entity_keys: [:agent],
      describe: """
      Configure a Jidoka agent.
      """,
      entities: [agent_entity()]
    }
  end
end
