defmodule JidokaTest.WebCapabilityTest do
  use JidokaTest.Support.Case, async: false

  alias Jidoka.Web.Tools.{ReadPage, SearchWeb, SnapshotUrl}
  alias JidokaTest.{WebReadOnlyAgent, WebSearchAgent}

  setup do
    previous_resolver = Application.get_env(:jidoka, :dns_resolver)

    Application.put_env(:jidoka, :dns_resolver, fn
      ~c"private.example", _family -> {:ok, [{127, 0, 0, 1}]}
      _host, :inet -> {:ok, [{93, 184, 216, 34}]}
      _host, :inet6 -> {:error, :nxdomain}
    end)

    on_exit(fn ->
      if previous_resolver do
        Application.put_env(:jidoka, :dns_resolver, previous_resolver)
      else
        Application.delete_env(:jidoka, :dns_resolver)
      end
    end)

    :ok
  end

  test "compiled agents expose search-only web capabilities" do
    assert [%Jidoka.Web{mode: :search, tools: [SearchWeb]}] = WebSearchAgent.web()
    assert WebSearchAgent.web_tool_names() == ["search_web"]
    assert WebSearchAgent.tools() == [SearchWeb]
    assert WebSearchAgent.tool_names() == ["search_web"]
  end

  test "compiled agents expose read-only web capabilities" do
    assert [
             %Jidoka.Web{
               mode: :read_only,
               tools: [SearchWeb, ReadPage, SnapshotUrl]
             }
           ] = WebReadOnlyAgent.web()

    assert WebReadOnlyAgent.web_tool_names() == ["search_web", "read_page", "snapshot_url"]
    assert WebReadOnlyAgent.tools() == [SearchWeb, ReadPage, SnapshotUrl]
  end

  test "web page tools reject local and private URLs before browser startup" do
    assert {:error, %Jidoka.Error.ValidationError{} = read_error} =
             ReadPage.run(%{url: "http://localhost:4000"}, %{})

    assert read_error.field == :url
    assert Jidoka.format_error(read_error) =~ "private network URLs are not allowed"

    assert {:error, %Jidoka.Error.ValidationError{} = snapshot_error} =
             SnapshotUrl.run(%{url: "http://192.168.1.10"}, %{})

    assert snapshot_error.field == :url
  end

  test "web page tools reject IPv6 loopback and embedded private IPv4 forms" do
    assert {:error, %Jidoka.Error.ValidationError{} = mapped_error} =
             ReadPage.run(%{url: "http://[::ffff:127.0.0.1]"}, %{})

    assert mapped_error.field == :url

    assert {:error, %Jidoka.Error.ValidationError{} = unspecified_error} =
             SnapshotUrl.run(%{url: "http://[::]"}, %{})

    assert unspecified_error.field == :url
  end

  test "web runtime clamps, truncates, and normalizes browser errors" do
    assert Jidoka.Web.Runtime.clamp_search_results(-10) == 1
    assert Jidoka.Web.Runtime.clamp_search_results(10_000) == Jidoka.Web.Config.max_results()
    assert Jidoka.Web.Runtime.clamp_search_results("bad") == Jidoka.Web.Config.max_results()

    assert Jidoka.Web.Runtime.clamp_content_chars(0) == 1
    assert Jidoka.Web.Runtime.clamp_content_chars(10_000_000) == Jidoka.Web.Config.max_content_chars()
    assert Jidoka.Web.Runtime.clamp_content_chars(nil) == Jidoka.Web.Config.max_content_chars()

    truncated = Jidoka.Web.Runtime.truncate_content(%{content: "abcdef"}, 3)
    assert truncated.content =~ "abc"
    assert truncated.content =~ "Content truncated"

    unchanged = Jidoka.Web.Runtime.truncate_content(%{"content" => "abc"}, 10)
    assert unchanged["content"] == "abc"

    assert %Jidoka.Error.ExecutionError{phase: :web, details: %{operation: :search_web, cause: :boom}} =
             Jidoka.Web.Runtime.normalize_browser_error(:search_web, :boom)
  end

  test "web runtime validates public URL shape without starting browser tools" do
    assert :ok = Jidoka.Web.Runtime.validate_public_url("https://example.com/docs")

    invalid_urls = [
      "ftp://example.com",
      "https:///missing-host",
      "https://service.localhost",
      "https://10.1.2.3",
      "https://172.20.1.1",
      "https://169.254.1.1",
      "https://private.example",
      "https://[fc00::1]",
      "https://[fe80::1]",
      "https://[ff00::1]",
      :not_a_url
    ]

    for url <- invalid_urls do
      assert {:error, %Jidoka.Error.ValidationError{field: :url}} =
               Jidoka.Web.Runtime.validate_public_url(url)
    end
  end

  test "read page validates format before delegating to browser" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             ReadPage.run(%{url: "https://example.com", format: "pdf"}, %{})

    assert error.field == :format
    assert error.details.reason == :invalid_format
  end

  test "web capability names conflict with other tool-like capabilities" do
    assert_raise Spark.Error.DslError, ~r/duplicate tool names.*search_web/s, fn ->
      compile_agent("""
      defmodule JidokaTest.WebDuplicateToolAgent do
        use Jidoka.Agent

        agent :web_duplicate_tool_agent do
          instructions "This should fail."
        end

        tools do
          action JidokaTest.DuplicateSearchWebTool
        end

        capabilities do
          web :search
        end
      end
      """)
    end
  end

  test "web capability rejects unsupported modes" do
    assert_raise Spark.Error.DslError, ~r/web capability mode must be :search or :read_only/s, fn ->
      compile_agent("""
      defmodule JidokaTest.WebBadModeAgent do
        use Jidoka.Agent

        agent :web_bad_mode_agent do
          instructions "This should fail."
        end

        capabilities do
          web :interactive
        end
      end
      """)
    end
  end

  test "web capability allows only one declaration" do
    assert_raise Spark.Error.DslError, ~r/at most one web capability/s, fn ->
      compile_agent("""
      defmodule JidokaTest.WebDuplicateDeclarationAgent do
        use Jidoka.Agent

        agent :web_duplicate_declaration_agent do
          instructions "This should fail."
        end

        capabilities do
          web :search
          web :read_only
        end
      end
      """)
    end
  end

  defp compile_agent(source), do: Code.compile_string(source)
end
