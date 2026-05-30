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

parse_positive_integer = fn value ->
  case Integer.parse(String.trim(value || "")) do
    {integer, ""} when integer > 0 -> integer
    _other -> nil
  end
end

default_max_model_turns = parse_positive_integer.(env["JIDOKA_DEFAULT_MAX_MODEL_TURNS"])
default_turn_timeout_ms = parse_positive_integer.(env["JIDOKA_DEFAULT_TURN_TIMEOUT_MS"])

if default_max_model_turns do
  config :jidoka, default_max_model_turns: default_max_model_turns
end

if default_turn_timeout_ms do
  config :jidoka, default_turn_timeout_ms: default_turn_timeout_ms
end
