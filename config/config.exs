import Config

config :jidoka,
  default_model: "openai:gpt-4o-mini",
  default_max_model_turns: 8,
  default_turn_timeout_ms: 30_000,
  default_generation: %{
    params: %{
      temperature: 0.0,
      max_tokens: 500
    }
  }

config :req_llm, load_dotenv: false

config :spark, :formatter,
  remove_parens?: true,
  "Jidoka.Agent": [
    type: Jidoka.Agent.SparkDsl,
    section_order: [:jidoka, :tools, :controls]
  ]

import_config "#{config_env()}.exs"
