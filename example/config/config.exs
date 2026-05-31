import Config

config :jidoka_example, JidokaExampleWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  secret_key_base: String.duplicate("a", 64),
  render_errors: [
    formats: [html: JidokaExampleWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: JidokaExample.PubSub,
  live_view: [signing_salt: "jidoka-example"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason
config :req_llm, load_dotenv: false
