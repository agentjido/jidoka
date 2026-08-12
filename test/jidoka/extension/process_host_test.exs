defmodule Jidoka.Extension.ProcessHostTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Jidoka.Extension.{Binding, ProcessHost, Registration, Request}
  alias Jidoka.TestSupport.ProcessExtensionTransport

  @hash "sha256:" <> String.duplicate("f", 64)

  test "exposes all declared slots without writing protocol stdout" do
    owner = self()

    output =
      capture_io(fn ->
        assert {:ok, pid} =
                 ProcessHost.start(binding: extension_binding(), descriptor: descriptor(owner), mode: :automation)

        assert {:ok, slots} = ProcessHost.slots(pid)

        assert {:ok, %{"tool" => "fixture_tool"}} = slots.tool_handlers["fixture_tool"].(%{}, %{})
        assert {:ok, %{"command" => "fixture_command"}} = slots.commands["fixture_command"].(%{})
        assert {:ok, %{"content" => "provider answer"}} = slots.providers["fixture_provider"].(%{})
        assert {:ok, %{"project" => "Atlas"}} = slots.context.(pid, %{})
        assert {:ok, %{"outcome" => "allow"}} = slots.policy_advice.(pid, %{})
        assert {:ok, %{"count" => 2}} = slots.checkpoint.(pid)
        assert slots.result == %{"answer" => 42}
        assert slots.ui_data == %{"panel" => "fixture"}

        event = Jidoka.Extension.Event.new!(%{name: "turn.start", event_id: "event-1", timestamp_ms: 1})
        assert :ok = slots.lifecycle.(event)

        assert ProcessHost.diagnostics(pid) == %{"stderr" => "fixture diagnostic"}
        assert :ok = ProcessHost.close(pid)
      end)

    assert output == ""
    assert_receive :transport_opened
    assert_receive {:protocol_frame, "initialize", _message}
    assert_receive {:protocol_notification, "lifecycle.notify", _message}
    assert_receive {:protocol_frame, "shutdown", _message}
    assert_receive :transport_closed
  end

  test "fails closed for missing constrained evidence and handshake mismatch and cleans up" do
    owner = self()
    unconstrained = descriptor(owner, evidence: %{"status" => "not_enforced"})

    assert {:error, %Jidoka.Extension.Error{code: :process_extension_start_failed}} =
             ProcessHost.start(binding: extension_binding(), descriptor: unconstrained, mode: :automation)

    assert_receive :transport_closed

    mismatches = [
      [wrong_identity: true],
      [protocol_version: 2],
      [permissions: ["tools"]],
      [capabilities: capabilities() ++ ["protocol.extra"]],
      [malformed_manifest: true]
    ]

    for mismatch <- mismatches do
      assert {:error, %Jidoka.Extension.Error{code: :process_extension_start_failed}} =
               ProcessHost.start(
                 binding: extension_binding(),
                 descriptor: descriptor(owner, mismatch),
                 mode: :automation
               )

      assert_receive :transport_closed
    end

    assert {:error, %Jidoka.Extension.Error{code: :process_extension_start_failed}} =
             ProcessHost.start(
               binding: extension_binding(),
               descriptor: descriptor(owner, behavior: :spawn_failure),
               mode: :automation
             )
  end

  test "normalizes undeclared calls, protocol noise, crashes, timeouts, cancellation, and cleanup failure" do
    owner = self()

    assert {:ok, pid} =
             ProcessHost.start(binding: extension_binding(), descriptor: descriptor(owner), mode: :automation)

    assert {:error, %Jidoka.Extension.Error{code: :process_extension_call_failed}} =
             ProcessHost.call(pid, "tool.call", %{"name" => "undeclared", "arguments" => %{}})

    assert :ok = ProcessHost.close(pid)

    for behavior <- [:malformed, :crash] do
      assert {:ok, pid} =
               ProcessHost.start(
                 binding: extension_binding(),
                 descriptor: descriptor(owner, behavior: behavior),
                 mode: :automation
               )

      assert {:error, %Jidoka.Extension.Error{code: :process_extension_call_failed}} =
               ProcessHost.call(pid, "tool.call", %{"name" => "fixture_tool", "arguments" => %{}})

      ProcessHost.close(pid)
    end

    assert {:ok, pid} =
             ProcessHost.start(
               binding: extension_binding(),
               descriptor: descriptor(owner, behavior: :hang, close_failure: true),
               mode: :automation,
               timeout_ms: 5
             )

    assert {:error, %Jidoka.Extension.Error{code: :process_extension_call_failed}} =
             ProcessHost.call(pid, "tool.call", %{"name" => "fixture_tool", "arguments" => %{}}, timeout_ms: 5)

    assert_receive {:transport_cancelled, _request_id}
    assert {:error, %Jidoka.Extension.Error{code: :process_extension_cleanup_failed}} = ProcessHost.close(pid)
  end

  defp descriptor(owner, overrides \\ []) do
    Map.merge(
      %{
        transport: ProcessExtensionTransport,
        owner: owner,
        evidence: %{"status" => "enforced", "isolation" => "container"},
        extension_id: "acme.process",
        identity_hash: @hash,
        permissions: permissions(),
        capabilities: capabilities()
      },
      Map.new(overrides)
    )
  end

  defp extension_binding do
    registration =
      Registration.new!(%{
        identity: %{
          id: "acme.process",
          source_type: :process,
          source_ref: "registry:acme-process",
          release: "1.0.0",
          content_hash: @hash,
          trust: :trusted
        },
        permissions: permissions(),
        capabilities: capabilities(),
        modes: [:interactive, :automation]
      })

    Binding.from(Request.new!(id: "acme.process"), registration, :automation)
  end

  defp permissions, do: ~w(context policy_advice providers results state tools ui_data)

  defp capabilities,
    do:
      ~w(protocol.command protocol.context protocol.lifecycle protocol.policy protocol.provider protocol.result protocol.state protocol.tool protocol.ui_data)
end
