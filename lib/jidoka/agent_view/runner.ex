defmodule Jidoka.AgentView.Runner do
  @moduledoc false

  alias Jidoka.Error
  alias Jidoka.Turn.Execution, as: TurnExecution

  @spec run_turn(module(), map(), String.t(), keyword()) ::
          {:ok, Jidoka.Turn.Result.t()}
          | {:hibernate, Jidoka.Snapshot.t()}
          | {:error, term()}
  def run_turn(view_module, %{conversation_id: conversation_id, runtime_context: runtime_context} = view, message, opts)
      when is_atom(view_module) and is_binary(message) and is_list(opts) do
    input = %{conversation_id: conversation_id, runtime_context: runtime_context}
    agent = view_module.agent_module(input)

    opts = Keyword.put_new(opts, :context, runtime_context)

    request_input =
      %{input: message, context: runtime_context}
      |> maybe_put_agent_state(Map.get(view.metadata, :agent_state))

    if loaded_agent_module?(agent) and function_exported?(agent, :run_turn, 2) do
      agent.run_turn(request_input, opts)
    else
      run_turn_execution(agent, request_input, opts)
    end
  end

  defp run_turn_execution(agent, request_input, opts) do
    case TurnExecution.run(agent, request_input, opts) do
      {:ok, _result} = ok -> ok
      {:hibernate, _snapshot} = hibernate -> hibernate
      {:error, reason} -> {:error, Error.normalize(reason, operation: :turn, phase: :harness)}
    end
  end

  defp maybe_put_agent_state(request_input, nil), do: request_input

  defp maybe_put_agent_state(request_input, agent_state),
    do: Map.put(request_input, :agent_state, agent_state)

  defp loaded_agent_module?(agent), do: is_atom(agent) and Code.ensure_loaded?(agent)
end
