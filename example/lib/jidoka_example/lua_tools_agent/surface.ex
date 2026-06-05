defmodule JidokaExample.LuaToolsAgent.Surface do
  @moduledoc false

  @type entry :: %{
          required(:id) => String.t(),
          required(:path) => [String.t()],
          required(:action) => module(),
          required(:description) => String.t(),
          required(:tags) => [String.t()],
          required(:read_only?) => boolean(),
          required(:returns) => String.t(),
          required(:example) => String.t()
        }

  @spec entries() :: [entry()]
  def entries do
    [
      %{
        id: "crm.customer.search",
        path: ["crm", "customer", "search"],
        action: JidokaExample.LuaToolsAgent.Actions.SearchCustomers,
        description: "Find CRM customers by name, company, status, tier, or tag.",
        tags: ["crm", "customer", "search", "account"],
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
        tags: ["billing", "invoice", "unpaid", "collections"],
        read_only?: true,
        returns:
          "Returns the JSON map directly. If assigned to local invoices, use invoices.invoices, invoices.total_due_cents, and invoices.count.",
        example:
          ~s|local invoices = billing.invoice.list_unpaid({customer_id = customer.id, limit = 5})|
      },
      %{
        id: "support.note.draft_followup",
        path: ["support", "note", "draft_followup"],
        action: JidokaExample.LuaToolsAgent.Actions.DraftFollowupNote,
        description:
          "Draft a support follow-up note for open invoice context. Required args: customer_name, company, invoice_count, total_due_cents.",
        tags: ["support", "note", "draft", "collections"],
        read_only?: true,
        returns:
          "Returns the JSON map directly. If assigned to local note, use note.note for the drafted customer message.",
        example:
          ~s|local note = support.note.draft_followup({customer_name = customer.name, company = customer.company, invoice_count = invoices.count, total_due_cents = invoices.total_due_cents})|
      }
    ]
  end

  @spec ids() :: [String.t()]
  def ids, do: Enum.map(entries(), & &1.id)

  @spec query(String.t(), keyword()) :: [map()]
  def query(query, opts \\ []) when is_binary(query) do
    limit = opts |> Keyword.get(:limit, 5) |> clamp_limit()
    normalized_query = normalize(query)

    entries()
    |> Enum.map(&{score(&1, normalized_query), &1})
    |> Enum.reject(fn {score, _entry} -> score <= 0 end)
    |> Enum.sort_by(fn {score, entry} -> {-score, entry.id} end)
    |> Enum.take(limit)
    |> Enum.map(fn {_score, entry} -> compact(entry) end)
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
    case Enum.find(entries(), &(&1.id == id)) do
      nil -> {:error, {:unknown_lua_tool, id}}
      entry -> {:ok, entry}
    end
  end

  @spec compact(entry()) :: map()
  def compact(entry) do
    %{
      "id" => entry.id,
      "lua_path" => Enum.join(entry.path, "."),
      "description" => entry.description,
      "returns" => entry.returns,
      "tags" => entry.tags,
      "read_only" => entry.read_only?
    }
  end

  @spec description(entry()) :: map()
  def description(entry) do
    tool = entry.action.to_tool()

    %{
      "id" => entry.id,
      "lua_path" => Enum.join(entry.path, "."),
      "description" => entry.description,
      "parameters_schema" => tool.parameters_schema,
      "returns" => entry.returns,
      "safety" => if(entry.read_only?, do: "read_only", else: "mutating"),
      "example" => entry.example
    }
  end

  defp score(_entry, ""), do: 1

  defp score(entry, query) do
    haystack =
      [entry.id, entry.description | entry.tags]
      |> Enum.join(" ")
      |> normalize()

    query
    |> String.split(" ", trim: true)
    |> Enum.count(&String.contains?(haystack, &1))
  end

  defp normalize(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.]+/, " ")
    |> String.trim()
  end

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(10)

  defp clamp_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _rest} -> clamp_limit(parsed)
      :error -> 5
    end
  end

  defp clamp_limit(_limit), do: 5
end
