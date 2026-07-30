defmodule JidokaShowcaseWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :jidoka_showcase

  @session_options [
    store: :cookie,
    key: "_jidoka_showcase_key",
    signing_salt: "jidoka-showcase"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/vendor/phoenix",
    from: {:phoenix, "priv/static"},
    gzip: false,
    only: ~w(phoenix.mjs)

  plug Plug.Static,
    at: "/vendor/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false,
    only: ~w(phoenix_live_view.esm.js)

  plug Plug.Static,
    at: "/",
    from: :jidoka_showcase,
    gzip: false,
    only: JidokaShowcaseWeb.static_paths()

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug JidokaShowcaseWeb.Router
end
