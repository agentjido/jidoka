defmodule JidokaExampleWeb.SessionPlug do
  @moduledoc false

  import Plug.Conn

  @session_key "jidoka_example_session_id"

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, @session_key) do
      id when is_binary(id) and id != "" ->
        conn

      _other ->
        put_session(conn, @session_key, Jidoka.Id.random("example_session"))
    end
  end
end
