defmodule Jidoka.Extension.ProtocolGoldenTest do
  use ExUnit.Case, async: true

  alias Jidoka.Extension.Protocol

  @fixtures Path.expand("../../fixtures/extension_protocol", __DIR__)

  test "golden request, response, notification, and error frames stay language-neutral" do
    expected = %{
      "initialize.jsonl" => %{"id" => "init-1", "method" => "initialize"},
      "tool_response.jsonl" => %{"id" => "tool-1", "result" => %{"content" => "done"}},
      "lifecycle_notification.jsonl" => %{"method" => "lifecycle.notify"},
      "error_response.jsonl" => %{"id" => "tool-2", "error" => %{"code" => -32_001}}
    }

    for {name, subset} <- expected do
      frame = File.read!(Path.join(@fixtures, name))
      assert String.ends_with?(frame, "\n")
      assert {:ok, decoded} = Protocol.decode(frame)

      for {key, value} <- subset do
        if is_map(value) do
          for {nested_key, nested_value} <- value, do: assert(decoded[key][nested_key] == nested_value)
        else
          assert decoded[key] == value
        end
      end
    end
  end
end
