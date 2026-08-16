defmodule Jidoka.Operation.Source.Catalog.Parameters do
  @moduledoc false

  def schema("query") do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "query" => %{"type" => "string"},
        "limit" => %{"type" => "integer", "default" => 5}
      },
      "required" => ["query"]
    }
  end

  def schema("describe") do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "ids" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["ids"]
    }
  end

  def schema("execute"),
    do: schema("execute", %{max_calls: 12, max_parallel_calls: 8, timeout: 1_500})

  def schema("execute", limits) when is_map(limits) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "script" => %{"type" => "string"},
        "allowed_tools" => %{"type" => "array", "items" => %{"type" => "string"}},
        "max_calls" => limit_schema(limits.max_calls),
        "max_parallel_calls" => limit_schema(limits.max_parallel_calls),
        "timeout" => limit_schema(limits.timeout)
      },
      "required" => ["script", "allowed_tools"]
    }
  end

  def schema(suffix, _limits), do: schema(suffix)

  defp limit_schema(maximum) do
    %{"type" => "integer", "minimum" => 1, "maximum" => maximum, "default" => maximum}
  end
end
