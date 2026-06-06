defmodule Jidoka.Agent.ToolSources.Catalog do
  @moduledoc false

  alias Jidoka.Agent.Dsl.Catalog
  alias Jidoka.Agent.ToolSources.Common
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.Catalog, as: CatalogSource
  alias Jidoka.Review.Approval

  @spec source!(term()) :: CatalogSource.t()
  def source!(%Catalog{} = catalog) do
    CatalogSource.new!(
      catalog: catalog.catalog,
      prefix: catalog.prefix || "catalog_",
      description: catalog.description,
      timeout: catalog.timeout || 1_500,
      max_calls: catalog.max_calls || 12,
      max_parallel_calls: catalog.max_parallel_calls || 8,
      require_read_only?: catalog.require_read_only? != false,
      result: catalog.result || :structured,
      idempotency: catalog.idempotency || :idempotent,
      metadata: catalog.metadata || %{}
    )
  end

  @spec operations!(term()) :: [Jidoka.Agent.Spec.Operation.t()]
  def operations!(%Catalog{} = catalog) do
    catalog
    |> source!()
    |> Source.operations()
    |> case do
      {:ok, operations} -> Approval.apply_to_operations!(operations, catalog.approval)
      {:error, reason} -> raise ArgumentError, "invalid catalog source: #{inspect(reason)}"
    end
  end

  @spec metadata!(term()) :: [map()]
  def metadata!(%Catalog{} = catalog) do
    source = source!(catalog)

    [
      %{
        "source" => "catalog",
        "catalog" => inspect(source.catalog),
        "catalog_id" => source.catalog_value.id,
        "prefix" => source.prefix,
        "timeout" => source.timeout,
        "max_calls" => source.max_calls,
        "max_parallel_calls" => source.max_parallel_calls,
        "require_read_only?" => source.require_read_only?,
        "result" => Atom.to_string(source.result),
        "tools" => Enum.map(Jido.Action.Catalog.list(source.catalog_value), & &1.id),
        "approval" => Approval.source_policy_map(catalog.approval)
      }
      |> Common.reject_nil_values()
    ]
  end
end
