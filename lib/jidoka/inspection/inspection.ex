defmodule Jidoka.Inspection do
  @moduledoc false

  alias Jido.AI.Request
  alias Jidoka.Session

  @type agent_definition :: map()
  @type running_agent_summary :: %{
          kind: :running_agent,
          id: term(),
          name: String.t() | nil,
          runtime_module: module(),
          owner_module: module() | nil,
          definition: map() | nil,
          request_count: non_neg_integer(),
          last_request_id: String.t() | nil,
          last_request: Jidoka.Debug.summary() | nil
        }

  @spec inspect_agent(module() | struct() | pid() | String.t()) ::
          {:ok, agent_definition() | running_agent_summary()} | {:error, term()}
  def inspect_agent(%Jidoka.ImportedAgent{} = agent),
    do: {:ok, Jidoka.ImportedAgent.definition(agent)}

  def inspect_agent(module) when is_atom(module) do
    _ = Code.ensure_loaded(module)

    cond do
      function_exported?(module, :__jidoka__, 0) ->
        {:ok, module.__jidoka__()}

      function_exported?(module, :__jidoka_definition__, 0) ->
        {:ok, module.__jidoka_definition__()}

      true ->
        {:error,
         Jidoka.Error.config_error("Module is not a Jidoka agent.",
           field: :agent,
           value: module,
           details: %{operation: :inspect_agent, reason: :not_jidoka_agent, cause: :not_jidoka_agent}
         )}
    end
  end

  def inspect_agent(server_or_id) do
    with {:ok, %{agent: agent, agent_module: runtime_module}} <-
           Jido.AgentServer.state(server_or_id) do
      definition = runtime_definition(runtime_module)
      last_request_id = last_request_id(agent)

      {:ok,
       %{
         kind: :running_agent,
         id: Map.get(agent, :id),
         name: Map.get(definition || %{}, :name, Map.get(agent, :name)),
         runtime_module: runtime_module,
         owner_module: runtime_owner_module(runtime_module),
         definition: definition,
         request_count: request_count(agent),
         last_request_id: last_request_id,
         last_request: request_summary(agent, last_request_id)
       }}
    end
  end

  @spec inspect_workflow(module()) :: {:ok, map()} | {:error, term()}
  def inspect_workflow(module) when is_atom(module), do: Jidoka.Workflow.inspect_workflow(module)

  @spec inspect_request(Session.t() | pid() | String.t() | Jido.Agent.t()) ::
          {:ok, Jidoka.Debug.summary()} | {:error, term()}
  def inspect_request(%Session{} = session) do
    case Session.whereis(session) do
      pid when is_pid(pid) -> Jidoka.Debug.request_summary(pid)
      nil -> {:error, session_not_running_error(session)}
    end
  end

  def inspect_request(server_or_agent), do: Jidoka.Debug.request_summary(server_or_agent)

  @spec inspect_request(Session.t() | pid() | String.t() | Jido.Agent.t(), String.t()) ::
          {:ok, Jidoka.Debug.summary()} | {:error, term()}
  def inspect_request(%Session{} = session, request_id) do
    case Session.whereis(session) do
      pid when is_pid(pid) -> request_summary_for_server(pid, request_id)
      nil -> {:error, session_not_running_error(session)}
    end
  end

  def inspect_request(%Jido.Agent{} = agent, request_id),
    do: Jidoka.Debug.request_summary(agent, request_id)

  def inspect_request(server_or_id, request_id) when is_pid(server_or_id) or is_binary(server_or_id),
    do: request_summary_for_server(server_or_id, request_id)

  def inspect_request(server_or_agent, request_id),
    do: Jidoka.Debug.request_summary(server_or_agent, request_id)

  defp session_not_running_error(%Session{} = session) do
    Jidoka.Error.validation_error("Session agent is not running.",
      field: :session,
      value: session.id,
      details: %{reason: :session_agent_not_running, agent_id: session.agent_id}
    )
  end

  defp request_summary_for_server(server_or_id, request_id) when is_binary(request_id) do
    with {:ok, server} <- resolve_server(server_or_id) do
      request_summary_for_resolved_server(server, request_id)
    else
      :error ->
        {:error, Jidoka.Error.Normalize.debug_error(:not_found, target: server_or_id)}
    end
  end

  defp request_summary_for_resolved_server(server, request_id) do
    case Jido.AgentServer.state(server) do
      {:ok, %{agent: %Jido.Agent{} = agent}} ->
        Jidoka.Debug.request_summary(agent, request_id)

      {:error, reason} ->
        {:error, Jidoka.Error.Normalize.debug_error(reason, target: server)}
    end
  end

  defp resolve_server(server) when is_pid(server), do: {:ok, server}

  defp resolve_server(server_id) when is_binary(server_id) do
    case Jidoka.Runtime.whereis(server_id) || jido_registry_whereis(server_id) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end

  defp resolve_server(server), do: {:ok, server}

  defp jido_registry_whereis(server_id) do
    Jido.AgentServer.whereis(Jido.Registry, server_id)
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp request_count(%{state: %{requests: requests}}) when is_map(requests),
    do: map_size(requests)

  defp request_count(_agent), do: 0

  defp last_request_id(%{state: %{last_request_id: request_id}}) when is_binary(request_id),
    do: request_id

  defp last_request_id(%{state: state}) when is_map(state) do
    case Map.get(state, :last_request_id) do
      request_id when is_binary(request_id) -> request_id
      _ -> nil
    end
  end

  defp last_request_id(_agent), do: nil

  defp request_summary(_agent, nil), do: nil

  defp request_summary(agent, request_id) when is_binary(request_id) do
    case Request.get_request(agent, request_id) do
      nil ->
        nil

      _request ->
        case Jidoka.Debug.request_summary(agent, request_id) do
          {:ok, summary} -> summary
          _ -> nil
        end
    end
  end

  defp runtime_definition(runtime_module) when is_atom(runtime_module) do
    if function_exported?(runtime_module, :__jidoka_definition__, 0) do
      runtime_module.__jidoka_definition__()
    else
      nil
    end
  end

  defp runtime_owner_module(runtime_module) when is_atom(runtime_module) do
    if function_exported?(runtime_module, :__jidoka_owner_module__, 0) do
      runtime_module.__jidoka_owner_module__()
    else
      nil
    end
  end
end
