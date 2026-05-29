import Config

config :jidoka,
  default_model: "openai:gpt-4o-mini",
  default_generation: %{
    params: %{
      temperature: 0.0,
      max_tokens: 500
    }
  }

config :req_llm, load_dotenv: false
