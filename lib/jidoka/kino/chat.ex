defmodule Jidoka.Kino.Chat do
  @moduledoc false

  alias Jidoka.Harness.Session
  alias Jidoka.Kino.{Render, RuntimeSetup, TraceView}
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn

  @doc false
  @spec chat(String.t(), (-> term()), keyword()) :: term()
  def chat(label, fun, opts \\ []) when is_binary(label) and is_function(fun, 0) do
    with :ok <- maybe_require_provider(opts) do
      result =
        label
        |> TraceView.trace(fun, opts)
        |> format_chat_result()

      if Keyword.get(opts, :render_result?, true) do
        render_chat_result(label, result)
      end

      result
    end
  end

  @doc false
  @spec format_chat_result(term()) :: term()
  def format_chat_result({:ok, %Turn.Result{content: content}}), do: {:ok, content}
  def format_chat_result({:ok, %Session{} = session, content}) when is_binary(content), do: {:ok, session, content}
  def format_chat_result({:ok, %Session{} = session, %Turn.Result{content: content}}), do: {:ok, session, content}

  def format_chat_result({:hibernate, %AgentSnapshot{} = snapshot}), do: {:hibernate, snapshot_summary(snapshot)}

  def format_chat_result({:hibernate, %Session{} = session, %AgentSnapshot{} = snapshot}),
    do: {:hibernate, session_summary(session), snapshot_summary(snapshot)}

  def format_chat_result({:error, reason}), do: {:error, Jidoka.Error.format(reason)}
  def format_chat_result(other), do: other

  defp maybe_require_provider(opts) do
    if Keyword.get(opts, :require_provider?, false) do
      opts
      |> Keyword.get(:provider_env, RuntimeSetup.provider_env_names(Keyword.get(opts, :provider)))
      |> RuntimeSetup.load_provider_env()
      |> case do
        {:ok, _source} -> :ok
        {:error, message} -> {:error, message}
      end
    else
      :ok
    end
  end

  defp render_chat_result(label, result) do
    Render.table("Turn result: #{label}", [chat_result_row(result)], keys: [:status, :summary])
  end

  defp chat_result_row({:ok, text}) when is_binary(text), do: %{status: "ok", summary: Render.preview(text, 320)}

  defp chat_result_row({:ok, %Session{} = session, text}) when is_binary(text) do
    %{status: "ok", summary: "#{session.session_id}: #{Render.preview(text, 260)}"}
  end

  defp chat_result_row({:hibernate, summary}) when is_map(summary),
    do: %{status: "hibernate", summary: Render.inspect_value(summary, 20)}

  defp chat_result_row({:hibernate, session, snapshot}) when is_map(session) and is_map(snapshot),
    do: %{status: "hibernate", summary: Render.inspect_value(%{session: session, snapshot: snapshot}, 20)}

  defp chat_result_row({:error, message}), do: %{status: "error", summary: to_string(message)}
  defp chat_result_row(other), do: %{status: "result", summary: Render.inspect_value(other, 50)}

  defp session_summary(%Session{} = session) do
    %{
      session_id: session.session_id,
      agent_id: session.agent_id,
      status: session.status,
      pending_reviews: length(session.pending_reviews)
    }
  end

  defp snapshot_summary(%AgentSnapshot{} = snapshot) do
    %{
      snapshot_id: snapshot.snapshot_id,
      agent_id: snapshot.agent_id,
      phase: snapshot.cursor.phase,
      status: snapshot.turn_state.status,
      pending_effects: length(snapshot.turn_state.pending_effects)
    }
  end
end
