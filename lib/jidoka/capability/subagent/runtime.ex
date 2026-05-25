defmodule Jidoka.Subagent.Runtime do
  @moduledoc false

  alias Jidoka.Subagent.Context
  alias Jidoka.Subagent.Runtime.{Calls, Executor, Result, Trace}

  @spec on_before_cmd(Jido.Agent.t(), term()) :: {:ok, Jido.Agent.t(), term()}
  def on_before_cmd(agent, {:ai_react_start, %{request_id: request_id} = params})
      when is_binary(request_id) do
    context = Map.get(params, :tool_context, %{}) || %{}

    context =
      context
      |> Map.put(Context.request_id_key(), request_id)
      |> Map.put(Context.server_key(), self())
      |> Map.put_new(Context.depth_key(), Context.current_depth(context))

    {:ok, agent, {:ai_react_start, Map.put(params, :tool_context, context)}}
  end

  def on_before_cmd(agent, action), do: {:ok, agent, action}

  @spec on_after_cmd(Jido.Agent.t(), term(), [term()]) :: {:ok, Jido.Agent.t(), [term()]}
  def on_after_cmd(agent, action, directives) do
    case request_id_from_action(action) do
      request_id when is_binary(request_id) ->
        subagent_calls = Calls.drain_request_meta(self(), request_id)

        if subagent_calls == [] do
          {:ok, agent, directives}
        else
          {:ok, Calls.put_request_meta(agent, request_id, %{calls: subagent_calls}), directives}
        end

      _ ->
        {:ok, agent, directives}
    end
  end

  @spec run_subagent_tool(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def run_subagent_tool(%{} = subagent, params, context)
      when is_map(params) and is_map(context) do
    case run_operation_control(context, subagent, params) do
      :ok ->
        Trace.emit(context, subagent, :start, %{input_keys: Context.map_keys(params)})

        case Executor.execute(subagent, params, context) do
          {:ok, result, metadata} ->
            Calls.record_metadata(context, metadata)
            Trace.emit(context, subagent, :stop, Trace.metadata(metadata))
            {:ok, Result.visible_result(subagent, result, metadata)}

          {:error, reason, metadata} ->
            Calls.record_metadata(context, metadata)
            Trace.emit(context, subagent, :error, Trace.metadata(metadata, %{error: Jidoka.Error.format(reason)}))
            {:error, Result.normalize_error(subagent, reason, context, metadata)}
        end

      {:interrupt, interrupt} ->
        {:error, {:interrupt, interrupt}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec run_subagent(map(), map(), map()) :: {:ok, String.t()} | {:error, term()}
  def run_subagent(%{} = subagent, params, context)
      when is_map(params) and is_map(context) do
    case run_operation_control(context, subagent, params) do
      :ok ->
        Trace.emit(context, subagent, :start, %{input_keys: Context.map_keys(params)})

        case Executor.execute(subagent, params, context) do
          {:ok, result, metadata} ->
            Calls.record_metadata(context, metadata)
            Trace.emit(context, subagent, :stop, Trace.metadata(metadata))
            {:ok, result}

          {:error, reason, metadata} ->
            Calls.record_metadata(context, metadata)
            Trace.emit(context, subagent, :error, Trace.metadata(metadata, %{error: Jidoka.Error.format(reason)}))
            {:error, Result.normalize_error(subagent, reason, context, metadata)}
        end

      {:interrupt, interrupt} ->
        {:error, {:interrupt, interrupt}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_request_meta(Jido.Agent.t(), String.t()) :: map() | nil
  defdelegate get_request_meta(agent, request_id), to: Calls

  @spec request_calls(pid() | String.t() | Jido.Agent.t(), String.t()) :: [map()]
  defdelegate request_calls(server_or_agent, request_id), to: Calls

  @spec latest_request_calls(pid() | String.t()) :: [map()]
  defdelegate latest_request_calls(server_or_id), to: Calls

  defp run_operation_control(context, subagent, params) do
    Jidoka.Guardrails.run_operation_control(context, %{
      operation_kind: :subagent,
      tool_name: subagent.name,
      tool_call_id: nil,
      arguments: params,
      context: context
    })
  end

  defp request_id_from_action({_action, params}), do: request_id_from_params(params)
  defp request_id_from_action(_action), do: nil

  defp request_id_from_params(%{request_id: request_id}) when is_binary(request_id), do: request_id
  defp request_id_from_params(%{"request_id" => request_id}) when is_binary(request_id), do: request_id
  defp request_id_from_params(%{event: event}), do: request_id_from_params(event)
  defp request_id_from_params(%{"event" => event}), do: request_id_from_params(event)
  defp request_id_from_params(_params), do: nil
end
