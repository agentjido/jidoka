import Config

example_root = Path.expand("..", __DIR__)
package_root = Path.expand("..", example_root)

env_files = [
  Path.join(package_root, ".env"),
  Path.join(example_root, ".env")
]

dotenv_files = Enum.filter(env_files, &File.exists?/1)
env = Dotenvy.source!([System.get_env() | dotenv_files] ++ [System.get_env()])

System.put_env(env)

config :req_llm,
  anthropic_api_key: env["ANTHROPIC_API_KEY"],
  openai_api_key: env["OPENAI_API_KEY"]

present? = fn value -> is_binary(value) and String.trim(value) != "" end

default_model =
  Enum.find(
    [
      env["JIDOKA_EXAMPLE_MODEL"],
      env["JIDOKA_DEFAULT_MODEL"],
      env["JIDOKA_LIVE_MODEL"],
      "openai:gpt-4o-mini"
    ],
    present?
  )

if is_binary(default_model) and String.trim(default_model) != "" do
  config :jidoka, default_model: default_model
end

config :jidoka_example,
  default_model: default_model,
  live_llm_ready?: present?.(env["OPENAI_API_KEY"]) or present?.(env["ANTHROPIC_API_KEY"])
