defmodule Jidoka.Extension.RegistrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Extension.{Identity, Registration}

  @hash "sha256:" <> String.duplicate("a", 64)

  test "builds portable pinned built-in and process registrations" do
    for source_type <- [:built_in, :process] do
      registration =
        Registration.new!(%{
          identity: %{
            id: "acme.context",
            source_type: source_type,
            source_ref: "registry:acme-context",
            release: "1.2.3",
            content_hash: @hash,
            trust: :trusted
          },
          permissions: ["context", "state"],
          capabilities: ["acme.context.read"],
          modes: [:interactive, :automation],
          protocol_version: 1,
          config_schema_id: "acme.context.config"
        })

      projection = Registration.to_map(registration)
      assert {:ok, _json} = Jason.encode(projection)
      refute inspect(projection) =~ "command"
      refute inspect(projection) =~ "Elixir."
      refute inspect(projection) =~ "#PID"
    end
  end

  test "rejects unpinned identities, host paths, invalid permissions, and protocol versions" do
    assert {:error, _reason} =
             Identity.new(%{
               id: "acme.context",
               source_type: :process,
               source_ref: "/usr/local/bin/acme",
               release: "1.0.0",
               content_hash: "main",
               trust: :trusted
             })

    base = %{
      identity: %{
        id: "acme.context",
        source_type: :built_in,
        source_ref: "registry:context",
        release: "1.0.0",
        content_hash: @hash,
        trust: :trusted
      },
      capabilities: []
    }

    assert {:error, _reason} = Registration.new(Map.put(base, :permissions, ["root_access"]))
    assert {:error, _reason} = Registration.new(Map.put(base, :protocol_version, 0))
    assert {:error, _reason} = Registration.new(Map.put(base, :version, 2))
  end
end
