defmodule Jidoka.Facade.AgentServer do
  @moduledoc false

  alias Jidoka.Error
  alias Jidoka.Runtime.AgentServerState
  alias Jidoka.Runtime.Signals

  @spec turn(Jido.AgentServer.server(), String.t(), keyword()) :: Jidoka.run_result()
  def turn(server, input, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    runtime_opts =
      opts
      |> Keyword.drop([:context, :metadata, :request_id, :timeout])
      |> Keyword.merge(Keyword.get(opts, :runtime_opts, []))

    signal =
      Signals.turn_run(input,
        request_id: Keyword.get(opts, :request_id),
        context: Keyword.get(opts, :context),
        metadata: Keyword.get(opts, :metadata),
        runtime_opts: runtime_opts
      )

    result =
      with {:ok, server} <- resolve_server_ref(server),
           {:ok, agent} <- Jido.AgentServer.call(server, signal, timeout) do
        run_result_from_jido_agent(agent)
      end

    case result do
      {:ok, _result} = ok ->
        ok

      {:hibernate, _snapshot} = hibernate ->
        hibernate

      {:error, reason} ->
        {:error,
         Error.normalize(reason,
           operation: :turn,
           phase: :agent_server,
           target: server,
           request_id: Keyword.get(opts, :request_id)
         )}
    end
  end

  @spec await(Jido.AgentServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def await(server, opts) do
    result =
      with {:ok, server} <- resolve_server_ref(server) do
        Jido.AgentServer.await_completion(server, opts)
      end

    case result do
      {:ok, _result} = ok ->
        ok

      {:error, reason} ->
        {:error, Error.normalize(reason, operation: :await_agent, target: server)}
    end
  end

  defp run_result_from_jido_agent(%Jido.Agent{state: state}) do
    case AgentServerState.from_jido_state(state) do
      {:ok, agent_server_state} ->
        AgentServerState.to_run_result(agent_server_state)

      {:error, reason} ->
        {:error, Error.normalize(reason, operation: :turn, phase: :agent_server)}
    end
  end

  defp resolve_server_ref(server) when is_binary(server) do
    case Jidoka.Jido.whereis(server) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  defp resolve_server_ref(server), do: {:ok, server}
end
