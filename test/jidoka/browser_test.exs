defmodule Jidoka.BrowserTest do
  use ExUnit.Case, async: false

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Browser
  alias Jidoka.Browser.Runtime
  alias Jidoka.Browser.Tools.{ReadPage, SearchWeb, SnapshotUrl}

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
      Browser.tool_modules(:interactive)
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

    assert :ok =
             Runtime.validate_allowlist("https://docs.example.com/guide", context, "read_page")

    assert :ok = Runtime.validate_allowlist("https://example.com", %{}, "read_page")

    assert {:error, %Jidoka.Error.ValidationError{details: %{reason: :browser_url_not_allowed}}} =
             Runtime.validate_allowlist("https://example.com", context, "read_page")
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

  defp restore_env(key, nil), do: Application.delete_env(:jidoka, key)
  defp restore_env(key, value), do: Application.put_env(:jidoka, key, value)
end
