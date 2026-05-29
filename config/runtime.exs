import Config

root_dir = Path.expand("..", __DIR__)
env_file = Path.join(root_dir, ".env")

env =
  [System.get_env(), env_file, System.get_env()]
  |> Dotenvy.source!()

System.put_env(env)

config :req_llm,
  anthropic_api_key: env["ANTHROPIC_API_KEY"],
  openai_api_key: env["OPENAI_API_KEY"]

default_model = env["JIDOKA_DEFAULT_MODEL"] || env["JIDOKA_LIVE_MODEL"]

if is_binary(default_model) and String.trim(default_model) != "" do
  config :jidoka, default_model: String.trim(default_model)
end
