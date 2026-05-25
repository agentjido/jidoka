defmodule Jidoka.AgentView.Start do
  @moduledoc false

  @spec start_agent(module(), term()) :: {:ok, pid()} | {:error, term()}
  def start_agent(view_module, %Jidoka.Session{} = session) when is_atom(view_module) do
    with :ok <- prepare_view(view_module, session) do
      agent_id = view_module.agent_id(session)
      agent = view_module.agent_module(session)

      with_start_lock(view_module, agent_id, fn ->
        start_or_reuse_session_agent(session, agent, agent_id)
      end)
    end
  end

  def start_agent(view_module, input) when is_atom(view_module) do
    with :ok <- prepare_view(view_module, input) do
      agent_id = view_module.agent_id(input)
      agent = view_module.agent_module(input)

      with_start_lock(view_module, agent_id, fn ->
        case Jidoka.Runtime.whereis(agent_id) do
          nil -> start_or_reuse_agent(agent, agent_id)
          pid -> {:ok, pid}
        end
      end)
    end
  end

  @spec prepare_view(module(), term()) :: :ok | {:error, term()}
  def prepare_view(view_module, input) when is_atom(view_module) do
    case view_module.prepare(input) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        error

      other ->
        {:error,
         Jidoka.Error.config_error("AgentView prepare/1 must return :ok or {:error, reason}.",
           value: other
         )}
    end
  end

  defp start_or_reuse_agent(agent, agent_id) do
    case start_agent_module(agent, agent_id) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_registered, pid}} when is_pid(pid) ->
        {:ok, pid}

      {:error, _reason} = error ->
        case Jidoka.Runtime.whereis(agent_id) do
          pid when is_pid(pid) -> {:ok, pid}
          nil -> error
        end
    end
  end

  defp start_or_reuse_session_agent(%Jidoka.Session{agent: agent, agent_id: agent_id} = session, agent, agent_id) do
    Jidoka.Session.start_agent(session)
  end

  defp start_or_reuse_session_agent(_session, agent, agent_id) do
    case Jidoka.Runtime.whereis(agent_id) do
      nil -> start_or_reuse_agent(agent, agent_id)
      pid -> {:ok, pid}
    end
  end

  defp start_agent_module(agent, agent_id) when is_atom(agent) do
    if function_exported?(agent, :start_link, 1) do
      apply(agent, :start_link, [[id: agent_id]])
    else
      Jidoka.Runtime.start_agent(agent, id: agent_id)
    end
  end

  defp start_agent_module(%Jidoka.ImportedAgent{} = agent, agent_id) do
    Jidoka.start_agent(agent, id: agent_id)
  end

  defp with_start_lock(view_module, agent_id, fun) when is_atom(view_module) and is_binary(agent_id) do
    lock_id = {{:jidoka_agent_view, view_module, agent_id}, self()}

    case :global.trans(lock_id, fun, [node()], 5) do
      :aborted -> {:error, Jidoka.Error.execution_error("Could not acquire agent start lock.", agent_id: agent_id)}
      result -> result
    end
  end
end
