defmodule JidokaExamples.WorkflowComposition.FulfillmentWorkflow do
  @moduledoc "Deterministic order fulfillment workflow used by the example agent."

  use Jidoka.Workflow

  alias JidokaExamples.WorkflowComposition.Functions

  workflow do
    id :fulfill_order
    description "Validates, routes, enriches, reserves, and ships one order."

    input Zoi.object(%{
            expedited: Zoi.boolean(),
            items:
              Zoi.array(
                Zoi.object(%{
                  quantity: Zoi.integer() |> Zoi.gt(0),
                  sku: Zoi.string(),
                  unit_price: Zoi.integer() |> Zoi.gte(0)
                })
              )
          })
  end

  steps do
    function :validate, {Functions, :validate, 2}, input: %{items: input(:items)}
    gate :expedited, condition: input(:expedited)

    function :priority_route, {Functions, :priority_route, 2},
      when: from(:expedited),
      input: %{}

    function :standard_route, {Functions, :standard_route, 2},
      unless: from(:expedited),
      input: %{}

    map :enrich_items,
      over: from(:validate, :items),
      function: {Functions, :enrich_item, 2},
      input: %{index: index(), item: item()},
      max_concurrency: 4

    reduce :summarize,
      over: from(:enrich_items),
      using: {Functions, :summarize, 2},
      input: %{
        items: items(),
        route: coalesce([maybe_from(:priority_route), maybe_from(:standard_route)])
      }

    function :reserve_inventory, {Functions, :reserve_inventory, 2},
      input: from(:summarize),
      retry: [max_attempts: 2, backoff: [type: :fixed, min: 0, max: 0]]

    loop(:ship_batches,
      initial: %{
        bonus_created: value(false),
        pending: from(:reserve_inventory, :items),
        shipped: value([])
      },
      using: {Functions, :ship_next, 2},
      input: %{state: loop_state(), iteration: iteration()},
      max_iterations: 10
    )

    function :finalize, {Functions, :finalize, 2},
      input: %{
        reservation: from(:reserve_inventory),
        route: coalesce([maybe_from(:priority_route), maybe_from(:standard_route)]),
        shipment: from(:ship_batches)
      }
  end

  output from(:finalize)
end
