defmodule Jidoka.Extension.HostTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Extension.{Host, Registration, Request}
  alias Jidoka.Session.Data, as: Session

  @hash "sha256:" <> String.duplicate("d", 64)

  test "opens every built-in slot and checkpoints only portable namespaced data" do
    owner = self()
    {:ok, session} = Session.start(spec(), session_id: "host-session")
    request = Request.new!(id: "acme.all")

    registry = %{
      "acme.all" => %{
        registration: registration("acme.all"),
        factory: factory(owner)
      }
    }

    assert {:ok, host} = Host.open(session, [request], registry, :interactive)
    assert [%Jidoka.Extension.OperationSource{}] = Host.operation_sources(host)
    assert is_function(Host.commands(host)["acme.command"], 1)
    assert is_function(Host.providers(host)["acme.provider"], 1)

    assert {:ok, %{"acme.all" => %{"project" => "Atlas"}}} =
             Host.context(host, %{input: "hello"})

    assert {:ok, %{"acme.all" => %{"outcome" => "allow"}}} =
             Host.policy_advice(host, :intent)

    assert {:ok, updated} = Host.checkpoint(host, session)
    assert Session.extension_state(updated) == %{"acme.all" => %{"count" => 2}}
    assert {:ok, restored} = Session.new(Map.from_struct(updated))
    assert Session.extension_state(restored) == Session.extension_state(updated)

    assert {:ok, %{"acme.all" => %{"answer" => 42}}} = Host.results(host)
    assert {:ok, [%{"status" => "closed"}]} = Host.close(host)
    assert_receive {:closed, :live_instance}
  end

  test "trusted host replacement and disable rules are not agent controlled" do
    defaults = %{"acme.default" => :default, "acme.keep" => :keep}
    replacements = %{"acme.default" => :replacement}

    assert Host.registry(defaults, replacements, ["acme.keep"]) == %{
             "acme.default" => :replacement
           }
  end

  test "close succeeds after the linked dispatcher stops" do
    {:ok, session} = Session.start(spec(), session_id: "stopped-dispatcher-session")
    {:ok, host} = Host.open(session, [], %{}, :interactive)
    :ok = GenServer.stop(host.dispatcher)

    assert {:ok, []} = Host.close(host)
  end

  test "fails before a turn on slot collisions, unknown slots, and bad result namespaces" do
    {:ok, session} = Session.start(spec(), session_id: "collision-session")
    first = Request.new!(id: "acme.first")
    second = Request.new!(id: "acme.second")
    operation = Operation.new!(name: "duplicate_tool", idempotency: :pure)

    registry = %{
      "acme.first" =>
        entry("acme.first", fn ->
          %{namespace: "acme.first", tools: [operation], tool_handlers: %{"duplicate_tool" => fn _, _ -> :ok end}}
        end),
      "acme.second" =>
        entry("acme.second", fn ->
          %{namespace: "acme.second", tools: [operation], tool_handlers: %{"duplicate_tool" => fn _, _ -> :ok end}}
        end)
    }

    assert {:error, %Jidoka.Extension.Error{code: :extension_slot_collision}} =
             Host.open(session, [first, second], registry, :interactive)

    bad_entry = entry("acme.first", fn -> %{namespace: "acme.first", unsupported: true} end)

    assert {:error, %Jidoka.Extension.Error{code: :extension_factory_failed}} =
             Host.open(session, [first], %{"acme.first" => bad_entry}, :interactive)

    core_entry = entry("acme.first", fn -> %{namespace: "core", result: %{"value" => 1}} end)

    assert {:error, %Jidoka.Extension.Error{code: :extension_factory_failed}} =
             Host.open(session, [first], %{"acme.first" => core_entry}, :interactive)
  end

  test "handler failure is stable and with_open always closes the instance" do
    owner = self()
    {:ok, session} = Session.start(spec(), session_id: "failure-session")
    request = Request.new!(id: "acme.failure")

    entry =
      entry("acme.failure", fn ->
        %{
          namespace: "acme.failure",
          context: fn _instance, _context -> raise "context failed" end,
          close: fn instance ->
            send(owner, {:closed, instance})
            :ok
          end
        }
      end)

    assert {:error, %Jidoka.Extension.Error{code: :extension_handler_failed}} =
             Host.with_open(session, [request], %{"acme.failure" => entry}, :interactive, fn host ->
               Host.context(host, %{})
             end)

    assert_receive {:closed, :instance}
  end

  defp factory(owner) do
    fn _binding, _config, %{state: restored} ->
      assert restored == %{}

      {:ok, :live_instance,
       %{
         namespace: "acme.all",
         tools: [Operation.new!(name: "acme_tool", idempotency: :pure)],
         tool_handlers: %{"acme_tool" => fn _arguments, _context -> {:ok, %{done: true}} end},
         commands: %{"acme.command" => fn _input -> {:ok, "done"} end},
         providers: %{"acme.provider" => fn _input -> {:ok, "answer"} end},
         policy_advice: fn _instance, _intent -> {:ok, %{"outcome" => "allow"}} end,
         context: fn _instance, _context -> {:ok, %{"project" => "Atlas"}} end,
         lifecycle: fn _event -> :ok end,
         state: %{"count" => 1},
         checkpoint: fn _instance -> {:ok, %{"count" => 2}} end,
         result: %{"answer" => 42},
         close: fn instance ->
           send(owner, {:closed, instance})
           :ok
         end
       }}
    end
  end

  defp entry(id, slots) do
    %{
      registration: registration(id),
      factory: fn _binding, _config, _context -> {:ok, :instance, slots.()} end
    }
  end

  defp registration(id) do
    Registration.new!(%{
      identity: %{
        id: id,
        source_type: :built_in,
        source_ref: "registry:#{id}",
        release: "1.0.0",
        content_hash: @hash,
        trust: :trusted
      },
      permissions: ["context", "policy_advice", "providers", "results", "state", "tools"],
      capabilities: ["#{id}.run"],
      modes: [:interactive, :automation]
    })
  end

  defp spec do
    Agent.Spec.new!(
      id: "extension_host_agent",
      instructions: "Test the extension host.",
      model: %{provider: :test, id: "model"}
    )
  end
end
