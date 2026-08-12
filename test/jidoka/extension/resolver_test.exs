defmodule Jidoka.Extension.ResolverTest do
  use ExUnit.Case, async: true

  alias Jidoka.Extension.{Binding, Registration, Request, Resolver}

  @hash "sha256:" <> String.duplicate("b", 64)

  test "resolves ordered built-in and process requests with minimum host grants" do
    first = request("acme.context")
    second = request("acme.tools", instance_id: "acme.tools.tests", mode: :automation)

    registry = %{
      "acme.context" => registration("acme.context", :built_in, ["context"]),
      "acme.tools" => %{
        registration: registration("acme.tools", :process, ["tools"]),
        validate_config: fn %{} -> :ok end,
        private_descriptor: %{command: "/trusted/host/path", module: __MODULE__}
      }
    }

    assert {:ok, [context, tools]} =
             Resolver.resolve_all([first, second], registry, :automation, allowed_permissions: ["context", "tools"])

    assert %Binding{request_id: "acme.context", mode: :automation} = context
    assert tools.instance_key == "acme.tools.tests"
    projection = Binding.to_map(tools)
    assert {:ok, _json} = Jason.encode(projection)
    refute inspect(projection) =~ "/trusted/host/path"
    refute inspect(projection) =~ inspect(__MODULE__)
  end

  test "fails closed for registry, trust, mode, permission, and config errors" do
    request = request("acme.context", config: %{"valid" => false})

    cases = [
      {%{}, :unknown_extension},
      {%{"acme.context" => [registration("acme.context"), registration("acme.context")]},
       :duplicate_extension_registration},
      {%{"acme.context" => registration("acme.context", :built_in, [], enabled: false)}, :extension_disabled},
      {%{"acme.context" => registration("acme.context", :built_in, [], trust: :untrusted)}, :extension_untrusted},
      {%{"acme.context" => registration("acme.context", :built_in, [], modes: [:interactive])},
       :extension_mode_not_supported},
      {%{"acme.context" => registration("acme.context", :built_in, ["tools"])}, :extension_permission_denied},
      {%{
         "acme.context" => %{
           registration: registration("acme.context"),
           validate_config: fn _config -> {:error, :bad_config} end
         }
       }, :extension_config_invalid}
    ]

    for {registry, code} <- cases do
      assert {:error, %Jidoka.Extension.Error{code: ^code}} =
               Resolver.resolve(request, registry, :automation, allowed_permissions: [])
    end

    assert {:error, %Jidoka.Extension.Error{code: :extension_registry_failure}} =
             Resolver.resolve(request, fn _id -> raise "registry unavailable" end, :automation)
  end

  test "resume rejects changed identity or permission grants" do
    request = request("acme.context")
    first = registration("acme.context", :built_in, ["context"])
    assert {:ok, binding} = Resolver.resolve(request, %{"acme.context" => first}, :interactive)

    changed_hash = "sha256:" <> String.duplicate("c", 64)
    changed = put_in(first.identity.content_hash, changed_hash)

    assert {:error, %Jidoka.Extension.Error{code: :extension_binding_changed}} =
             Resolver.resolve(request, %{"acme.context" => changed}, :interactive, resume_binding: binding)

    changed_permissions = %{first | permissions: Jidoka.Extension.PermissionSet.new!(["context", "state"])}

    assert {:error, %Jidoka.Extension.Error{code: :extension_binding_changed}} =
             Resolver.resolve(request, %{"acme.context" => changed_permissions}, :interactive, resume_binding: binding)
  end

  defp request(id, attrs \\ []) do
    attrs |> Map.new() |> Map.put(:id, id) |> Request.new!()
  end

  defp registration(id, source_type \\ :built_in, permissions \\ [], overrides \\ []) do
    identity = %{
      id: id,
      source_type: source_type,
      source_ref: "registry:#{id}",
      release: "1.0.0",
      content_hash: @hash,
      trust: Keyword.get(overrides, :trust, :trusted)
    }

    Registration.new!(%{
      identity: identity,
      permissions: permissions,
      capabilities: ["#{id}.run"],
      modes: Keyword.get(overrides, :modes, [:interactive, :automation]),
      enabled: Keyword.get(overrides, :enabled, true),
      protocol_version: 1
    })
  end
end
