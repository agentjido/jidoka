defmodule JidokaExamples.Ash.User do
  use Ash.Resource,
    domain: JidokaExamples.Ash.Accounts,
    extensions: [AshJido],
    validate_domain_inclusion?: false

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string)
  end

  actions do
    default_accept([:name])
    create(:create)
    read(:read)
  end

  jido do
    action(:create)
    action(:read)
  end
end
