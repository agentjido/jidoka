defmodule JidokaShowcase.AshAgent.Resources.Customer do
  @moduledoc false

  use Ash.Resource,
    domain: JidokaShowcase.AshAgent.Domain,
    extensions: [AshJido],
    data_layer: Ash.DataLayer.Ets

  ets do
    table(:jidoka_showcase_customers)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:company, :string, allow_nil?: false, public?: true)
    attribute(:tier, :string, allow_nil?: false, public?: true)
    attribute(:health_score, :integer, allow_nil?: false, public?: true)
    attribute(:notes, :string, public?: true)

    timestamps()
  end

  identities do
    identity(:unique_name, [:name],
      pre_check?: true,
      message: "customer name must be unique"
    )
  end

  actions do
    defaults([:read])

    create :create do
      description("Create a customer record")

      accept([:name, :company, :tier, :health_score, :notes])
    end
  end

  jido do
    action(:create, name: "create_customer")
    action(:read, name: "list_customers", max_page_size: 20, query_params?: false)
  end
end
