defmodule Jidoka.Harness.Store.InMemory do
  @moduledoc """
  In-memory harness store for tests, examples, and local exploration.

  The store is an `Agent` process containing session data keyed by session id.
  It is intentionally small and makes no persistence guarantees.
  """

  @behaviour Jidoka.Harness.Store

  alias Jidoka.Harness.Session

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, opts)
  end

  @impl true
  def put_session(%Session{} = session, opts) do
    pid = fetch_pid!(opts)

    Agent.update(pid, &Map.put(&1, session.session_id, session))
    {:ok, session}
  end

  @impl true
  def get_session(session_id, opts) when is_binary(session_id) do
    pid = fetch_pid!(opts)

    case Agent.get(pid, &Map.get(&1, session_id)) do
      %Session{} = session -> {:ok, session}
      nil -> {:error, {:session_not_found, session_id}}
    end
  end

  @impl true
  def list_sessions(opts) do
    pid = fetch_pid!(opts)

    sessions =
      pid
      |> Agent.get(&Map.values/1)
      |> Enum.sort_by(& &1.session_id)

    {:ok, sessions}
  end

  defp fetch_pid!(opts) do
    case Keyword.fetch(opts, :pid) do
      {:ok, pid} when is_pid(pid) -> pid
      {:ok, name} when is_atom(name) -> name
      :error -> raise ArgumentError, "in-memory harness store requires :pid"
    end
  end
end
