defmodule JidokaExample.LuaToolsAgent.Surface do
  @moduledoc false

  alias Jido.Action.Catalog
  alias Jido.Action.Catalog.Entry

  @type entry :: Entry.t()

  @spec catalog() :: Catalog.t()
  def catalog do
    Enum.reduce(entries_metadata(), Catalog.new!(catalog_attrs()), fn metadata, catalog ->
      Catalog.register!(
        catalog,
        metadata.action,
        id: metadata.id,
        description: metadata.description,
        summary: metadata.description,
        namespace: metadata.namespace,
        tags: metadata.tags,
        capabilities: metadata.capabilities,
        visibility: :hidden,
        risk: :low,
        read_only?: metadata.read_only?,
        metadata: %{
          "lua" => %{
            "path" => metadata.path,
            "returns" => metadata.returns,
            "example" => metadata.example
          }
        }
      )
    end)
  end

  defp catalog_attrs do
    [
      id: "jidoka-example-lua-tools",
      name: "Jidoka Example Lua Tools",
      description: "Hidden read-only host actions exposed through the Lua tools demo.",
      metadata: %{"surface" => "lua_tools"}
    ]
  end

  defp entries_metadata do
    [
      %{
        id: "crm.customer.search",
        path: ["crm", "customer", "search"],
        action: JidokaExample.LuaToolsAgent.Actions.SearchCustomers,
        description: "Find CRM customers by name, company, status, tier, or tag.",
        namespace: "crm.customer",
        tags: ["crm", "customer", "search", "account"],
        capabilities: ["search", "customer_lookup"],
        read_only?: true,
        returns:
          "Returns the JSON map directly. If assigned to local search, use search.customers for the customer list and search.count for the total count.",
        example: ~s|local search = crm.customer.search({query = "Northwind", limit = 2})|
      },
      %{
        id: "billing.invoice.list_unpaid",
        path: ["billing", "invoice", "list_unpaid"],
        action: JidokaExample.LuaToolsAgent.Actions.ListUnpaidInvoices,
        description: "List unpaid invoices for a customer id.",
        namespace: "billing.invoice",
        tags: ["billing", "invoice", "unpaid", "collections"],
        capabilities: ["invoice_lookup", "collections"],
        read_only?: true,
        returns:
          "Returns the JSON map directly. If assigned to local invoices, use invoices.invoices, invoices.total_due_cents, and invoices.count.",
        example: ~s|local invoices = billing.invoice.list_unpaid({customer_id = customer.id, limit = 5})|
      },
      %{
        id: "support.note.draft_followup",
        path: ["support", "note", "draft_followup"],
        action: JidokaExample.LuaToolsAgent.Actions.DraftFollowupNote,
        description:
          "Draft a support follow-up note for open invoice context. Required args: customer_name, company, invoice_count, total_due_cents.",
        namespace: "support.note",
        tags: ["support", "note", "draft", "collections"],
        capabilities: ["draft_note", "collections"],
        read_only?: true,
        returns:
          "Returns the JSON map directly. If assigned to local note, use note.note for the drafted customer message.",
        example:
          ~s|local note = support.note.draft_followup({customer_name = customer.name, company = customer.company, invoice_count = invoices.count, total_due_cents = invoices.total_due_cents})|
      }
    ]
  end

  @spec entries() :: [entry()]
  def entries, do: Catalog.list(catalog())

  @spec ids() :: [String.t()]
  def ids, do: Enum.map(entries(), & &1.id)

  @spec query(String.t(), keyword()) :: [map()]
  def query(query, opts \\ []) when is_binary(query) do
    limit = opts |> Keyword.get(:limit, 5) |> clamp_limit()

    {:ok, hits} =
      Catalog.search(catalog(), %{
        text: query,
        limit: limit,
        visibility: [:hidden],
        filters: %{read_only?: true}
      })

    Enum.map(hits, &compact(&1.entry))
  end

  @spec describe([String.t()]) :: {:ok, [map()]} | {:error, term()}
  def describe(ids) when is_list(ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, descriptions} ->
      case fetch(id) do
        {:ok, entry} -> {:cont, {:ok, descriptions ++ [description(entry)]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec fetch(String.t()) :: {:ok, entry()} | {:error, term()}
  def fetch(id) when is_binary(id) do
    case Catalog.fetch(catalog(), id) do
      {:ok, %Entry{} = entry} -> {:ok, entry}
      {:error, _reason} -> {:error, {:unknown_lua_tool, id}}
    end
  end

  @spec compact(entry()) :: map()
  def compact(entry) do
    %{
      "id" => entry.id,
      "lua_path" => entry |> lua_path() |> Enum.join("."),
      "description" => entry.description,
      "returns" => lua_metadata(entry, "returns"),
      "tags" => entry.tags,
      "read_only" => entry.read_only?
    }
  end

  @spec description(entry()) :: map()
  def description(entry) do
    tool = entry.module.to_tool()

    %{
      "id" => entry.id,
      "lua_path" => entry |> lua_path() |> Enum.join("."),
      "description" => entry.description,
      "parameters_schema" => tool.parameters_schema,
      "returns" => lua_metadata(entry, "returns"),
      "safety" => if(entry.read_only?, do: "read_only", else: "mutating"),
      "example" => lua_metadata(entry, "example")
    }
  end

  @spec lua_path(entry()) :: [String.t()]
  def lua_path(%Entry{} = entry), do: lua_metadata(entry, "path") || []

  defp lua_metadata(%Entry{metadata: %{"lua" => metadata}}, key), do: Map.get(metadata, key)
  defp lua_metadata(%Entry{metadata: %{lua: metadata}}, key), do: Map.get(metadata, key)
  defp lua_metadata(_entry, _key), do: nil

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(10)

  defp clamp_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _rest} -> clamp_limit(parsed)
      :error -> 5
    end
  end

  defp clamp_limit(_limit), do: 5
end
