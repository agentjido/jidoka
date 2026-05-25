defmodule Jidoka.Agent.Definition.ScheduleConfig do
  @moduledoc false

  @spec resolve!(module()) :: [Jidoka.Schedule.t()]
  def resolve!(owner_module) do
    owner_module
    |> Jidoka.Agent.Definition.agent_contract!()
    |> Map.get(:schedules, [])
    |> then(&(&1 || []))
    |> Enum.map(&resolve_schedule!(owner_module, &1))
  end

  defp resolve_schedule!(owner_module, %Jidoka.Agent.Dsl.Schedule{} = entity) do
    schedule_id = "#{agent_id(owner_module)}:#{entity.name}"

    opts = [
      id: schedule_id,
      agent_id: normalize_agent_id(entity.agent_id, schedule_id),
      cron: entity.cron,
      timezone: entity.timezone,
      prompt: entity.prompt,
      context: entity.context,
      conversation: entity.conversation,
      overlap: entity.overlap,
      timeout: entity.timeout,
      enabled?: entity.enabled?
    ]

    case Jidoka.Schedule.new(owner_module, opts) do
      {:ok, schedule} ->
        schedule

      {:error, reason} ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: Jidoka.Error.format(reason),
                path: [:jidoka, :agent, :schedule],
                value: entity,
                hint: "Place `schedule :name do cron \"0 9 * * *\" prompt \"...\" end` inside `agent :id do ... end`.",
                module: owner_module,
                location: Map.get(entity.__spark_metadata__ || %{}, :anno)
              )
    end
  end

  defp normalize_agent_id(nil, schedule_id), do: schedule_id
  defp normalize_agent_id(agent_id, _schedule_id) when is_atom(agent_id), do: Atom.to_string(agent_id)
  defp normalize_agent_id(agent_id, _schedule_id), do: agent_id

  defp agent_id(owner_module) do
    owner_module
    |> Jidoka.Agent.Definition.agent_contract!()
    |> Map.fetch!(:id)
    |> then(&Jidoka.Agent.Definition.Basics.resolve_agent_id!(owner_module, &1))
  end
end
