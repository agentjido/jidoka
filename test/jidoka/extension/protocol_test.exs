defmodule Jidoka.Extension.ProtocolTest do
  use ExUnit.Case, async: true

  alias Jidoka.Extension.{Binding, Protocol, Registration, Request}

  @hash "sha256:" <> String.duplicate("e", 64)

  test "completes a handshake and encodes every version-1 method" do
    session = Protocol.new(extension_binding())
    assert {:ok, initialize, session} = Protocol.initialize(session, "init-1", :automation)
    assert String.ends_with?(initialize, "\n")
    assert {:error, :protocol_not_initialized} = Protocol.request(session, "early", "health", %{})

    response =
      Protocol.response("init-1", %{
        "protocol_version" => 1,
        "extension_id" => "acme.process",
        "identity_hash" => @hash,
        "granted_permissions" => permissions(),
        "capabilities" => capabilities()
      })
      |> elem(1)

    assert {:ok, %{"result" => result}, session} = Protocol.receive_line(session, response)
    assert {:ok, session} = Protocol.complete_initialize(session, result)

    methods = Protocol.methods() -- ["initialize"]

    final =
      Enum.reduce(Enum.with_index(methods), session, fn {method, index}, state ->
        assert {:ok, frame, next} = Protocol.request(state, "request-#{index}", method, params(method))
        assert {:ok, decoded} = Protocol.decode(frame)
        assert decoded["method"] == method
        next
      end)

    assert MapSet.size(final.pending) == length(methods)
  end

  test "rejects malformed framing, duplicate IDs, secrets, bad negotiation, and undeclared calls" do
    session = initialized_session()

    assert {:error, _reason} = Protocol.decode("noise\n{}\n")
    assert {:error, _reason} = Protocol.decode("not-json\n")
    assert {:error, _reason} = Protocol.decode(String.duplicate("x", 1_048_577))
    assert {:error, _reason} = Protocol.encode(%{"jsonrpc" => "2.0", "api_key" => "secret"})

    assert {:ok, _frame, session} = Protocol.request(session, "duplicate", "health", %{})
    assert {:error, {:duplicate_protocol_id, "duplicate"}} = Protocol.request(session, "duplicate", "health", %{})

    assert {:error, {:unsolicited_protocol_response, "unknown"}} =
             Protocol.receive_line(session, elem(Protocol.response("unknown", %{}), 1))

    bad_result = %{
      "protocol_version" => 2,
      "extension_id" => "acme.process",
      "identity_hash" => @hash,
      "granted_permissions" => permissions(),
      "capabilities" => capabilities()
    }

    assert {:error, {:protocol_initialize_mismatch, 2}} =
             Protocol.complete_initialize(Protocol.new(extension_binding()), bad_result)

    limited = %{session | capabilities: MapSet.delete(session.capabilities, "protocol.tool")}

    assert {:error, {:protocol_capability_not_declared, "protocol.tool"}} =
             Protocol.request(limited, "tool-1", "tool.call", params("tool.call"))
  end

  test "timeout, cancellation, child error, and shutdown races are deterministic" do
    session = initialized_session()
    assert {:ok, _frame, session} = Protocol.request(session, "slow", "health", %{})
    assert {:ok, timed_out} = Protocol.timeout(session, "slow")

    assert {:error, {:unsolicited_protocol_response, "slow"}} =
             Protocol.receive_line(timed_out, elem(Protocol.response("slow", %{}), 1))

    assert {:ok, cancel_frame} = Protocol.notification(timed_out, "request.cancel", %{"id" => "slow"})
    assert Protocol.decode(cancel_frame) |> elem(0) == :ok

    assert {:ok, _frame, session} = Protocol.request(timed_out, "failed", "health", %{})
    error_frame = elem(Protocol.error_response("failed", -32_001, "child failed", %{"kind" => "runtime"}), 1)
    assert {:ok, %{"error" => %{"code" => -32_001}}, session} = Protocol.receive_line(session, error_frame)

    closed = Protocol.close(session)
    assert {:error, :protocol_closed} = Protocol.request(closed, "late", "health", %{})
  end

  defp initialized_session do
    session = Protocol.new(extension_binding())

    Protocol.complete_initialize(session, %{
      "protocol_version" => 1,
      "extension_id" => "acme.process",
      "identity_hash" => @hash,
      "granted_permissions" => permissions(),
      "capabilities" => capabilities()
    })
    |> elem(1)
  end

  defp extension_binding do
    request = Request.new!(id: "acme.process")

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

    Binding.from(request, registration, :automation)
  end

  defp permissions, do: ~w(context policy_advice providers results state tools ui_data)

  defp capabilities,
    do:
      ~w(protocol.command protocol.context protocol.lifecycle protocol.policy protocol.provider protocol.result protocol.state protocol.tool protocol.ui_data)

  defp params("tool.call"), do: %{"name" => "read", "arguments" => %{}}
  defp params("command.call"), do: %{"name" => "format", "input" => %{}}
  defp params("provider.start"), do: %{"provider" => "test", "request" => %{}}
  defp params(method) when method in ["provider.update", "provider.cancel"], do: %{"correlation_id" => "provider-1"}
  defp params("lifecycle.notify"), do: %{"event" => %{"name" => "turn.start"}}
  defp params("state.restore"), do: %{"state" => %{}}

  defp params(method) when method in ["result.update", "ui_data.update"],
    do: %{"namespace" => "acme.process", "data" => %{}}

  defp params("request.cancel"), do: %{"id" => "request-1"}
  defp params(_method), do: %{}
end
