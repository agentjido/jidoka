defmodule JidokaExampleWeb.AgentSourceComponents do
  @moduledoc false

  use JidokaExampleWeb, :html

  attr :examples, :list, required: true
  attr :active_source, :string, required: true

  def source_examples(assigns) do
    assigns =
      assign(assigns,
        selected: selected_source(assigns.examples, assigns.active_source)
      )

    ~H"""
    <div class="source-nav">
      <%= for example <- @examples do %>
        <button
          class={source_tab_class(@selected.id, example.id)}
          type="button"
          phx-click="show_source"
          phx-value-source={example.id}
        >
          {example.label}
        </button>
      <% end %>
    </div>

    <section class="source-file">
      <div class="source-file-header">
        <h3>{@selected.label}</h3>
        <span>{@selected.path}</span>
      </div>

      <pre class="code-block"><code><%= raw(highlight_elixir(@selected.source)) %></code></pre>
    </section>
    """
  end

  defp selected_source(examples, active_source) do
    Enum.find(examples, &(&1.id == active_source)) || hd(examples)
  end

  defp source_tab_class(active_source, source),
    do: ["source-nav-link", active_source == source && "active"]

  defp highlight_elixir(source) do
    source
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace(~r/(&quot;.*?&quot;)/, ~s(<span class="code-string">\\1</span>))
    |> String.replace(~r/(#.*)$/m, ~s(<span class="code-comment">\\1</span>))
    |> String.replace(
      ~r/\b(defmodule|defp?|use|alias|do|end|agent|tools|controls|action|browser|ash_resource|catalog|instructions|model|generation|max_turns|timeout)\b/,
      ~s(<span class="code-keyword">\\1</span>)
    )
    |> String.replace(~r/(:[a-zA-Z_][a-zA-Z0-9_?!]*)/, ~s(<span class="code-atom">\\1</span>))
  end
end
