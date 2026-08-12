defmodule Jidoka.TestSupport.ProcessExtensionTransport do
  @moduledoc false

  @behaviour Jidoka.Extension.ProcessTransport

  alias Jidoka.Extension.Protocol

  @impl true
  def open(descriptor, _opts) do
    send(descriptor.owner, :transport_opened)

    if descriptor[:behavior] == :spawn_failure,
      do: {:error, :spawn_failed},
      else: {:ok, %{descriptor: descriptor}, descriptor.evidence}
  end

  @impl true
  def exchange(%{descriptor: descriptor} = handle, frame, _timeout) do
    {:ok, message} = Protocol.decode(frame)
    method = message["method"]
    send(descriptor.owner, {:protocol_frame, method, message})

    exchange_result(descriptor[:behavior], method, handle, message, descriptor)
  end

  @impl true
  def notify(%{descriptor: descriptor} = handle, frame) do
    {:ok, message} = Protocol.decode(frame)
    send(descriptor.owner, {:protocol_notification, message["method"], message})
    {:ok, handle}
  end

  @impl true
  def cancel(%{descriptor: descriptor}, request_id) do
    send(descriptor.owner, {:transport_cancelled, request_id})
    :ok
  end

  @impl true
  def close(%{descriptor: descriptor}, _opts) do
    send(descriptor.owner, :transport_closed)
    if descriptor[:close_failure], do: {:error, :close_failed}, else: :ok
  end

  @impl true
  def diagnostics(_handle), do: %{"stderr" => "fixture diagnostic", "api_key" => "remove-me"}

  defp response(handle, message, result) do
    {:ok, frame} = Protocol.response(message["id"], result)
    {:ok, frame, handle}
  end

  defp exchange_result(:hang, "tool.call", handle, message, _descriptor) do
    Process.sleep(5_000)
    response(handle, message, %{})
  end

  defp exchange_result(:crash, "tool.call", _handle, _message, _descriptor),
    do: raise("transport crashed")

  defp exchange_result(:malformed, "tool.call", handle, _message, _descriptor),
    do: {:ok, "protocol noise\n", handle}

  defp exchange_result(_behavior, "initialize", handle, message, descriptor),
    do: response(handle, message, manifest(descriptor))

  defp exchange_result(_behavior, "context.contribute", handle, message, _descriptor),
    do: response(handle, message, %{"project" => "Atlas"})

  defp exchange_result(_behavior, "policy.advise", handle, message, _descriptor),
    do: response(handle, message, %{"outcome" => "allow"})

  defp exchange_result(_behavior, "state.restore", handle, message, _descriptor),
    do: response(handle, message, %{"restored" => true})

  defp exchange_result(_behavior, "state.checkpoint", handle, message, _descriptor),
    do: response(handle, message, %{"count" => 2})

  defp exchange_result(_behavior, "tool.call", handle, message, _descriptor),
    do: response(handle, message, %{"tool" => message["params"]["name"]})

  defp exchange_result(_behavior, "command.call", handle, message, _descriptor),
    do: response(handle, message, %{"command" => message["params"]["name"]})

  defp exchange_result(_behavior, "provider.start", handle, message, _descriptor),
    do: response(handle, message, %{"content" => "provider answer"})

  defp exchange_result(_behavior, "shutdown", handle, message, _descriptor),
    do: response(handle, message, %{"closed" => true})

  defp exchange_result(_behavior, _method, handle, message, _descriptor),
    do: response(handle, message, %{})

  defp manifest(descriptor) do
    identity_hash =
      if descriptor[:wrong_identity],
        do: "sha256:" <> String.duplicate("0", 64),
        else: descriptor.identity_hash

    manifest = %{
      "protocol_version" => descriptor[:protocol_version] || 1,
      "extension_id" => descriptor.extension_id,
      "identity_hash" => identity_hash,
      "granted_permissions" => descriptor.permissions,
      "capabilities" => descriptor.capabilities,
      "tools" => [
        %{
          "name" => "fixture_tool",
          "description" => "Runs the fixture tool.",
          "idempotency" => "pure"
        }
      ],
      "commands" => ["fixture_command"],
      "providers" => ["fixture_provider"],
      "context" => true,
      "policy_advice" => true,
      "state" => %{"count" => 1},
      "result" => %{"answer" => 42},
      "ui_data" => %{"panel" => "fixture"}
    }

    if descriptor[:malformed_manifest],
      do: Map.put(manifest, "tools", [%{"description" => "missing name"}]),
      else: manifest
  end
end
