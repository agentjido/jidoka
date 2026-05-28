defmodule JidokaExamples.Knowledge.PolicyPlugin do
  use Jidoka.Plugin,
    description: "Publishes the policy lookup tool.",
    tools: [JidokaExamples.Knowledge.PolicyLookup]
end
