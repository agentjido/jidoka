defmodule Jidoka.Runtime.Actions.RunTurn do
  @moduledoc """
  Jido action that runs one Jidoka turn inside `Jido.AgentServer`.

  `Jido.AgentServer` routes a turn signal to this action. The action executes
  the Jidoka harness, then writes the durable turn outcome back into the Jido
  agent state so normal Jido status, await, hibernate, and inspection APIs can
  see the result.
  """

  use Jido.Action,
    name: "jidoka_run_turn",
    description: "Run one Jidoka agent turn"

  alias Jidoka.Runtime.AgentServerState
  alias Jidoka.Turn

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    with {:ok, input} <- fetch_input(params),
         {:ok, agent_module} <- fetch_agent_module(context),
         {:ok, request} <- build_request(input, params, context) do
      params
      |> runtime_opts(context)
      |> then(&run_agent_turn(agent_module, request, &1))
      |> state_from_run_result(request)
      |> then(&{:ok, &1})
    else
      {:error, reason} -> {:ok, failed_state(reason, current_jidoka_state(context))}
    end
  end

  def run(_params, _context), do: {:ok, failed_state(:invalid_turn_params)}

  defp fetch_input(params) do
    case get(params, :input) do
      input when is_binary(input) and input != "" -> {:ok, input}
      _other -> {:error, :missing_input}
    end
  end

  defp fetch_agent_module(%{agent: %{agent_module: module}}) when is_atom(module),
    do: {:ok, module}

  defp fetch_agent_module(%{agent_module: module}) when is_atom(module), do: {:ok, module}
  defp fetch_agent_module(_context), do: {:error, :missing_agent_module}

  defp build_request(input, params, context) do
    attrs =
      %{
        input: input,
        agent_state: current_jidoka_state(context),
        context: get(params, :context, %{}),
        metadata: get(params, :metadata, %{})
      }
      |> maybe_put(:request_id, get(params, :request_id))

    Turn.Request.new(attrs)
  end

  defp current_jidoka_state(%{state: state}) when is_map(state) do
    AgentServerState.current_agent_state(state)
  end

  defp current_jidoka_state(_context), do: AgentServerState.new!().agent_state

  defp runtime_opts(params, context) do
    params
    |> get(:runtime_opts, [])
    |> normalize_runtime_opts()
    |> maybe_put_session_id(params)
    |> Keyword.update(:operation_context, operation_context(params, context), fn existing ->
      Map.merge(operation_context(params, context), normalize_context(existing))
    end)
  end

  defp maybe_put_session_id(opts, params) do
    context = params |> get(:context, %{}) |> normalize_context()

    case Map.get(context, :session_id, Map.get(context, "session_id")) do
      session_id when is_binary(session_id) -> Keyword.put_new(opts, :session_id, session_id)
      _other -> opts
    end
  end

  defp normalize_runtime_opts(opts) when is_list(opts), do: opts
  defp normalize_runtime_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_runtime_opts(_opts), do: []

  defp normalize_context(context) when is_list(context), do: Map.new(context)
  defp normalize_context(context) when is_map(context), do: context
  defp normalize_context(_context), do: %{}

  defp run_agent_turn(agent_module, request, opts) do
    agent_module.run_turn(request, opts)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp operation_context(params, context) do
    %{}
    |> maybe_put(:jido_agent, Map.get(context, :agent))
    |> maybe_put(:jido_agent_server_pid, Map.get(context, :agent_server_pid))
    |> Map.merge(normalize_context(get(params, :context, %{})))
  end

  defp state_from_run_result({:ok, %Turn.Result{} = result}, %Turn.Request{} = request) do
    result
    |> AgentServerState.completed(request)
    |> AgentServerState.to_jido_state()
  end

  defp state_from_run_result({:hibernate, snapshot}, %Turn.Request{} = request) do
    snapshot
    |> AgentServerState.hibernated(request)
    |> AgentServerState.to_jido_state()
  end

  defp state_from_run_result({:error, reason}, %Turn.Request{} = request),
    do: failed_state(reason, request.agent_state, request_id: request.request_id)

  defp failed_state(reason, agent_state \\ AgentServerState.new!().agent_state, context \\ []) do
    reason
    |> AgentServerState.failed(
      agent_state,
      Keyword.merge([operation: :run_turn, phase: :agent_server], context)
    )
    |> AgentServerState.to_jido_state()
  end

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
