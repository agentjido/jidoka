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

  def schema("execute") do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "script" => %{"type" => "string"},
        "allowed_tools" => %{"type" => "array", "items" => %{"type" => "string"}},
        "max_calls" => %{"type" => "integer"},
        "max_parallel_calls" => %{"type" => "integer"},
        "timeout" => %{"type" => "integer"}
      },
      "required" => ["script", "allowed_tools"]
    }
  end
end
