defmodule Jidoka.Agent.ToolSources.Browser do
  @moduledoc false

  alias Jidoka.Agent.Dsl.Browser
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Agent.ToolSources.Common
  alias Jidoka.Review.Approval

  @spec action_modules(term()) :: [module()]
  def action_modules(%Browser{} = browser) do
    browser
    |> mode!()
    |> Jidoka.Browser.tool_modules()
  end

  @spec operations!(term()) :: [Operation.t()]
  def operations!(%Browser{} = browser) do
    browser
    |> action_modules()
    |> Enum.map(&Common.operation_from_action!/1)
    |> Enum.map(&tag_operation(&1, browser))
    |> Approval.apply_to_operations!(browser.approval)
  end

  @spec metadata!(term()) :: [map()]
  def metadata!(%Browser{} = browser) do
    [
      %{
        "source" => "browser",
        "name" => Common.normalize_name!(browser.name, "browser name"),
        "mode" => Atom.to_string(mode!(browser)),
        "allow" => Common.normalize_string_list!(browser.allow || [], "browser allowlist"),
        "approval" => Approval.source_policy_map(browser.approval)
      }
      |> Common.reject_nil_values()
    ]
  end

  defp tag_operation(%Operation{metadata: metadata} = operation, %Browser{} = browser) do
    browser_name = Common.normalize_name!(browser.name, "browser name")
    mode = mode!(browser)

    Operation.new!(%Operation{
      operation
      | description: browser.description || operation.description,
        idempotency: browser.idempotency || operation.idempotency,
        metadata:
          metadata
          |> Map.merge(Common.normalize_metadata!(browser.metadata))
          |> Map.merge(%{
            "source" => "browser",
            "kind" => "browser",
            "browser" => browser_name,
            "mode" => Atom.to_string(mode),
            "allow" => Common.normalize_string_list!(browser.allow || [], "browser allowlist")
          })
    })
  end

  defp mode!(%Browser{} = browser) do
    case Jidoka.Browser.normalize_mode(browser.mode || :read_only) do
      {:ok, mode} -> mode
      {:error, reason} -> raise ArgumentError, reason
    end
  end
end
