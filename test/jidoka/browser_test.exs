defmodule Jidoka.BrowserTest do
  use ExUnit.Case, async: false

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Browser
  alias Jidoka.Adapter.Jido.Browser, as: Runtime
  alias Jidoka.Adapter.Jido.Browser.Tools.{ReadPage, SearchWeb, SnapshotUrl}

  defmodule FakeBrowserAction do
    @moduledoc false

    def run(params, context), do: {:ok, %{params: params, context: context}}
  end

  defmodule FakePageAction do
    @moduledoc false

    def run(params, _context), do: {:ok, %{content: "abcdef", params: params}}
  end

  setup do
    previous_resolver = Application.get_env(:jidoka, :dns_resolver)
    previous_browser_actions = Application.get_env(:jidoka, :browser_actions)
    previous_max_results = Application.get_env(:jidoka, :browser_max_results)
    previous_max_content_chars = Application.get_env(:jidoka, :browser_max_content_chars)

    Application.put_env(:jidoka, :browser_actions, %{
      search_web: FakeBrowserAction,
      read_page: FakePageAction,
      snapshot_url: FakePageAction
    })

    Application.put_env(:jidoka, :dns_resolver, fn
      ~c"docs.example.com", _family -> {:ok, [{93, 184, 216, 34}]}
      ~c"example.com", _family -> {:ok, [{93, 184, 216, 34}]}
      ~c"internal.example.com", _family -> {:ok, [{10, 0, 0, 5}]}
      _host, _family -> {:error, :nxdomain}
    end)

    on_exit(fn ->
      if is_nil(previous_resolver) do
        Application.delete_env(:jidoka, :dns_resolver)
      else
        Application.put_env(:jidoka, :dns_resolver, previous_resolver)
      end

      restore_env(:browser_actions, previous_browser_actions)
      restore_env(:browser_max_results, previous_max_results)
      restore_env(:browser_max_content_chars, previous_max_content_chars)
    end)
  end

  test "browser modes expand to constrained action modules" do
    assert Browser.tool_modules(:search) == [SearchWeb]
    assert Browser.tool_modules("search") == [SearchWeb]
    assert Browser.tool_modules(:read_only) == [SearchWeb, ReadPage, SnapshotUrl]
    assert Browser.normalize_mode("read_only") == {:ok, :read_only}
    assert {:error, _reason} = Browser.normalize_mode("interactive")

    assert_raise ArgumentError, ~r/browser mode must be :search or :read_only/, fn ->
      apply(Browser, :tool_modules, [:interactive])
    end
  end

  test "runtime clamps, truncates, and validates public URLs" do
    Application.put_env(:jidoka, :browser_max_results, 4)
    Application.put_env(:jidoka, :browser_max_content_chars, 12)

    assert Runtime.max_results() == 4
    assert Runtime.max_content_chars() == 12
    assert Runtime.clamp_search_results(999) == 4
    assert Runtime.clamp_content_chars(999) == 12
    assert Runtime.clamp_search_results(-10) == 1
    assert Runtime.clamp_search_results(:bad) == Runtime.max_results()
    assert Runtime.clamp_content_chars(-10) == 1
    assert Runtime.clamp_content_chars(:bad) == Runtime.max_content_chars()

    assert Runtime.truncate_content(%{content: "abcdef"}, 3).content =~ "abc"
    assert Runtime.truncate_content(%{content: "abc"}, 10).content == "abc"
    assert :ok = Runtime.validate_public_url("https://example.com/page")

    assert {:ok, %{params: %{ok: true}, context: %{request_id: "r1"}}} =
             Runtime.delegate(FakeBrowserAction, %{ok: true}, %{request_id: "r1"})

    assert {:error, %Jidoka.Error.ValidationError{details: %{reason: :invalid_url}}} =
             Runtime.validate_public_url("file:///tmp/data")

    assert {:error, %Jidoka.Error.ValidationError{details: %{reason: :invalid_url}}} =
             Runtime.validate_public_url("http://localhost:4000")

    assert {:error, %Jidoka.Error.ValidationError{details: %{reason: :invalid_url}}} =
             Runtime.validate_public_url("https://internal.example.com")

    assert {:error, %Jidoka.Error.ValidationError{details: %{reason: :invalid_url}}} =
             Runtime.validate_public_url("https://missing.example.com")

    assert {:error, %Jidoka.Error.ValidationError{details: %{reason: :invalid_url}}} =
             Runtime.validate_public_url("http://192.168.1.1")

    assert {:error, %Jidoka.Error.ValidationError{details: %{reason: :invalid_url}}} =
             Runtime.validate_public_url("http://[fd00::1]")

    assert {:error, %Jidoka.Error.ValidationError{details: %{reason: :invalid_url}}} =
             Runtime.validate_public_url(:not_a_url)
  end

  test "runtime enforces optional browser allowlists from operation metadata" do
    operation =
      Operation.new!(
        name: "read_page",
        metadata: %{"allow" => ["docs.example.com"]}
      )

    context = Jidoka.Context.from_data!(%{}, runtime: %{jidoka_spec: %{operations: [operation]}})
    action_context = Jidoka.Context.to_action_context(context)

    assert :ok =
             Runtime.validate_allowlist("https://docs.example.com/guide", context, "read_page")

    assert :ok =
             Runtime.validate_allowlist("https://docs.example.com/guide", action_context, "read_page")

    assert :ok = Runtime.validate_allowlist("https://example.com", %{}, "read_page")

    assert {:error, %Jidoka.Error.ValidationError{details: %{reason: :browser_url_not_allowed}}} =
             Runtime.validate_allowlist("https://example.com", context, "read_page")

    assert {:error, %Jidoka.Error.ValidationError{details: %{reason: :browser_url_not_allowed}}} =
             Runtime.validate_allowlist("https://example.com", action_context, "read_page")

    assert {:error, %Jidoka.Error.ValidationError{details: %{reason: :browser_url_not_allowed}}} =
             Runtime.validate_allowlist(:not_a_url, action_context, "read_page")

    missing_operation_context =
      Jidoka.Context.from_data!(%{}, runtime: %{jidoka_spec: %{operations: []}})
      |> Jidoka.Context.to_action_context()

    assert :ok =
             Runtime.validate_allowlist(
               "https://example.com",
               missing_operation_context,
               "read_page"
             )
  end

  test "browser allowlists reject prefix-confused hosts and enforce URL paths" do
    operation =
      Operation.new!(
        name: "read_page",
        metadata: %{"allow" => ["https://docs.example.com/guides"]}
      )

    context = Jidoka.Context.from_data!(%{}, runtime: %{jidoka_spec: %{operations: [operation]}})

    assert :ok =
             Runtime.validate_allowlist("https://docs.example.com/guides/setup", context, "read_page")

    assert {:error, %Jidoka.Error.ValidationError{details: %{reason: :browser_url_not_allowed}}} =
             Runtime.validate_allowlist("https://docs.example.com.evil.test/guides", context, "read_page")

    assert {:error, %Jidoka.Error.ValidationError{details: %{reason: :browser_url_not_allowed}}} =
             Runtime.validate_allowlist("https://docs.example.com/admin", context, "read_page")
  end

  test "browser tools fail predictably when a target action is unavailable" do
    assert {:error, %Jidoka.Error.ExecutionError{phase: :browser}} =
             Runtime.delegate(Jido.Browser.Actions.MissingAction, %{}, %{})
  end

  test "browser tools delegate through configured Jido-browser action modules" do
    data_context = Jidoka.Context.from_data!(request_id: "r1")

    assert {:ok, %{params: search_params, context: %Jidoka.Context{} = delegated_context}} =
             SearchWeb.run(%{query: "  jidoka  ", max_results: 99}, data_context)

    assert Jidoka.Context.get(delegated_context, :request_id) == "r1"
    assert search_params.query == "jidoka"
    assert search_params.max_results == Runtime.max_results()

    context =
      Jidoka.Context.from_data!(%{},
        runtime: %{
          jidoka_spec: %{
            operations: [
              Operation.new!(name: "read_page", metadata: %{"allow" => ["docs.example.com"]}),
              Operation.new!(name: "snapshot_url", metadata: %{allow: ["docs.example.com"]})
            ]
          }
        }
      )

    assert {:ok, %{content: content, params: read_params}} =
             ReadPage.run(
               %{
                 url: "https://docs.example.com/guide",
                 selector: "main",
                 format: :text,
                 max_chars: 3
               },
               context
             )

    assert content =~ "abc"
    assert content =~ "[Content truncated by Jidoka.Browser.]"

    assert read_params == %{
             url: "https://docs.example.com/guide",
             selector: "main",
             format: :text
           }

    assert {:ok, %{content: content, params: snapshot_params}} =
             SnapshotUrl.run(
               %{
                 url: "https://docs.example.com/guide",
                 selector: "main",
                 include_links: false,
                 include_headings: true,
                 include_forms: true,
                 max_content_length: 3
               },
               context
             )

    assert content =~ "abc"

    assert snapshot_params == %{
             url: "https://docs.example.com/guide",
             selector: "main",
             include_links: false,
             include_headings: true,
             include_forms: true,
             max_content_length: 3
           }
  end

  test "browser page tools validate URL and format before delegation" do
    assert {:error, %Jidoka.Error.ValidationError{details: %{reason: :invalid_format}}} =
             ReadPage.run(%{url: "https://example.com", format: "pdf"}, Jidoka.Context.from_data!(%{}))

    assert {:error, %Jidoka.Error.ValidationError{details: %{reason: :invalid_url}}} =
             SnapshotUrl.run(%{url: "http://localhost/private"}, Jidoka.Context.from_data!(%{}))
  end

  test "normalizes delegated browser failures" do
    assert %Jidoka.Error.ExecutionError{phase: :browser, details: details} =
             Runtime.normalize_browser_error(:read_page, :boom)

    assert details.operation == :read_page
    assert details.target == :jido_browser
    assert details.cause == :boom
  end

  test "rejects every private address class and malformed public target" do
    private_urls = [
      "http://127.2.3.4",
      "http://169.254.1.2",
      "http://172.16.1.2",
      "http://172.31.1.2",
      "http://0.1.2.3",
      "http://[::]",
      "http://[::ffff:127.0.0.1]",
      "http://[fe80::1]",
      "http://[ff00::1]"
    ]

    for url <- private_urls do
      assert {:error, %Jidoka.Error.ValidationError{details: %{reason: :invalid_url}}} =
               Runtime.validate_public_url(url)
    end

    assert {:error, %Jidoka.Error.ValidationError{details: %{reason: :invalid_url}}} =
             Runtime.validate_public_url("http:///missing-host")

    Application.put_env(:jidoka, :dns_resolver, fn
      ~c"loopback.test", _family -> {:ok, [{127, 0, 0, 2}]}
      ~c"link-local.test", _family -> {:ok, [{169, 254, 2, 3}]}
      ~c"private-172.test", _family -> {:ok, [{172, 20, 2, 3}]}
      ~c"unspecified.test", _family -> {:ok, [{0, 2, 3, 4}]}
      ~c"ipv6-zero.test", _family -> {:ok, [{0, 0, 0, 0, 0, 0, 0, 0}]}
      ~c"ipv6-loopback.test", _family -> {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}]}
      ~c"ipv6-mapped.test", _family -> {:ok, [{0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}]}
      ~c"ipv6-unique.test", _family -> {:ok, [{0xFC00, 0, 0, 0, 0, 0, 0, 1}]}
      ~c"ipv6-link.test", _family -> {:ok, [{0xFE80, 0, 0, 0, 0, 0, 0, 1}]}
      ~c"ipv6-multicast.test", _family -> {:ok, [{0xFF00, 0, 0, 0, 0, 0, 0, 1}]}
      ~c"public.test", _family -> {:ok, [{93, 184, 216, 34}, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}]}
      ~c"resolver-error.test", _family -> raise "resolver failed"
    end)

    for host <- [
          "loopback.test",
          "link-local.test",
          "private-172.test",
          "unspecified.test",
          "ipv6-zero.test",
          "ipv6-loopback.test",
          "ipv6-mapped.test",
          "ipv6-unique.test",
          "ipv6-link.test",
          "ipv6-multicast.test",
          "resolver-error.test"
        ] do
      assert {:error, %Jidoka.Error.ValidationError{details: %{reason: :invalid_url}}} =
               Runtime.validate_public_url("https://#{host}")
    end

    assert :ok = Runtime.validate_public_url("https://public.test")
  end

  test "covers allowlist scope, path, and content boundary forms" do
    operation =
      Operation.new!(
        name: "read_page",
        metadata: %{
          allow: [
            "",
            "ftp://docs.example.com",
            "https://docs.example.com",
            "http://docs.example.com",
            "https://docs.example.com:444/",
            "https://docs.example.com/guide%20one"
          ]
        }
      )

    context = Jidoka.Context.from_data!(%{}, runtime: %{jidoka_spec: %{operations: [operation]}})

    assert :ok = Runtime.validate_allowlist("https://docs.example.com/anything", context, "read_page")
    assert :ok = Runtime.validate_allowlist("http://docs.example.com/anything", context, "read_page")
    assert :ok = Runtime.validate_allowlist("https://docs.example.com:444/anything", context, "read_page")
    assert :ok = Runtime.validate_allowlist("https://docs.example.com/guide%20one/page", context, "read_page")

    assert {:error, %Jidoka.Error.ValidationError{}} =
             Runtime.validate_allowlist("https://docs.example.com:445/anything", context, "read_page")

    assert Runtime.truncate_content(%{"content" => "abcdef", content: 12}, 3) == %{
             "content" => "abc\n\n[Content truncated by Jidoka.Browser.]",
             content: 12
           }
  end

  defp restore_env(key, nil), do: Application.delete_env(:jidoka, key)
  defp restore_env(key, value), do: Application.put_env(:jidoka, key, value)
end
