defmodule JidokaExample.AshAgentTest do
  use ExUnit.Case, async: false

  alias JidokaExample.AshAgent.Domain
  alias JidokaExample.AshAgent.Resources.Customer

  setup do
    if :ets.whereis(:jidoka_example_customers) != :undefined do
      :ets.delete_all_objects(:jidoka_example_customers)
    end

    :ok
  end

  test "customer records are visible across action process boundaries" do
    context = %{domain: Domain}

    assert {:ok, _customer} =
             Task.async(fn ->
               Customer.Jido.Create.run(
                 %{
                   name: "Ada Lovelace",
                   company: "Northwind",
                   tier: "enterprise",
                   health_score: 91,
                   notes: "expansion candidate"
                 },
                 context
               )
             end)
             |> Task.await()

    assert {:ok, %{result: customers}} =
             Task.async(fn -> Customer.Jido.Read.run(%{}, context) end)
             |> Task.await()

    assert Enum.any?(customers, &(&1.name == "Ada Lovelace"))
  end

  test "customer names are unique" do
    context = %{domain: Domain}
    params = customer_params(%{name: "Charles Babbage"})

    assert {:ok, _customer} = Customer.Jido.Create.run(params, context)
    assert {:error, error} = Customer.Jido.Create.run(params, context)

    assert Exception.message(error) =~ "customer name must be unique"

    assert {:ok, %{result: customers}} = Customer.Jido.Read.run(%{}, context)
    assert Enum.count(customers, &(&1.name == "Charles Babbage")) == 1
  end

  test "list customers action does not expose query filters to the LLM" do
    refute Keyword.has_key?(Customer.Jido.Read.schema(), :filter)
    refute Keyword.has_key?(Customer.Jido.Read.schema(), :sort)
  end

  defp customer_params(overrides) do
    Map.merge(
      %{
        name: "Ada Lovelace",
        company: "Northwind",
        tier: "enterprise",
        health_score: 91,
        notes: "expansion candidate"
      },
      overrides
    )
  end
end
