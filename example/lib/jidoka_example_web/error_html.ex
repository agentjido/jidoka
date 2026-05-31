defmodule JidokaExampleWeb.ErrorHTML do
  @moduledoc false

  use JidokaExampleWeb, :html

  def render(_template, assigns) do
    ~H"""
    <main class="page">
      <h1>Request failed</h1>
      <p class="subtle">{status_message(assigns[:conn] && assigns.conn.status)}</p>
    </main>
    """
  end

  defp status_message(404), do: "The route was not found."
  defp status_message(500), do: "The server returned an error."
  defp status_message(_status), do: "The request could not be completed."
end
