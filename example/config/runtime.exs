import Config

env = JidokaExample.Env.load!()

config :req_llm,
  anthropic_api_key: env["ANTHROPIC_API_KEY"],
  openai_api_key: env["OPENAI_API_KEY"]

default_model = JidokaExample.Env.model(env)

if is_binary(default_model) and String.trim(default_model) != "" do
  config :jidoka, default_model: default_model
end
