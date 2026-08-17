defmodule Jidoka.Projection.Memory do
  @moduledoc false

  alias Jidoka.Memory
  alias Jidoka.Portable

  @spec project(
          Memory.Entry.t()
          | Memory.Route.t()
          | Memory.RecallRequest.t()
          | Memory.RecallResult.t()
          | Memory.WriteRequest.t()
          | Memory.WriteResult.t()
          | nil
        ) :: map() | nil
  def project(nil), do: nil

  def project(%Memory.Entry{} = entry) do
    %{
      id: entry.id,
      agent_id: entry.agent_id,
      session_id: entry.session_id,
      content: entry.content,
      metadata: Portable.project(entry.metadata)
    }
    |> reject_nil_values()
  end

  def project(%Memory.Route{} = route) do
    route
    |> Map.from_struct()
    |> Portable.project()
    |> reject_nil_values()
  end

  def project(%Memory.RecallRequest{} = request) do
    %{
      route: project(request.route),
      query: request.query,
      limit: request.limit,
      metadata: Portable.project(request.metadata)
    }
    |> reject_nil_values()
  end

  def project(%Memory.RecallResult{} = result) do
    %{
      request: project(result.request),
      entries: Enum.map(result.entries, &project/1),
      metadata: Portable.project(result.metadata)
    }
  end

  def project(%Memory.WriteRequest{} = request) do
    %{
      entry: project(request.entry),
      route: project(request.route),
      idempotency_key: request.idempotency_key,
      metadata: Portable.project(request.metadata)
    }
    |> reject_nil_values()
  end

  def project(%Memory.WriteResult{} = result) do
    %{
      request: project(result.request),
      entry: project(result.entry),
      status: result.status,
      metadata: Portable.project(result.metadata)
    }
  end

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
