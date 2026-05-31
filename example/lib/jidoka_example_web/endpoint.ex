defmodule JidokaExampleWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :jidoka_example

  @session_options [
    store: :cookie,
    key: "_jidoka_example_key",
    signing_salt: "jidoka-example"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :jidoka_example,
    gzip: false,
    only: JidokaExampleWeb.static_paths()

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug JidokaExampleWeb.Router
end
