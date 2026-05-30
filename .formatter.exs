# Used by "mix format"
[
  plugins: [Spark.Formatter],
  locals_without_parens: [
    action: 1,
    agent: 1,
    agent: 2,
    controls: 1,
    context: 1,
    generation: 1,
    input: 1,
    instructions: 1,
    max_turns: 1,
    model: 1,
    operation: 1,
    operation: 2,
    result: 1,
    timeout: 1,
    tools: 1
  ],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
