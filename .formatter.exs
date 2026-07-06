# Used by "mix format"

spark_locals_without_parens = [
  action: 1,
  agent: 1,
  agent: 2,
  ash_resource: 1,
  ash_resource: 2,
  browser: 1,
  browser: 2,
  catalog: 1,
  catalog: 2,
  coalesce: 1,
  context: 1,
  controls: 1,
  description: 1,
  from: 1,
  from: 2,
  function: 3,
  gate: 2,
  generation: 1,
  handoff: 1,
  handoff: 2,
  id: 1,
  index: 0,
  input: 1,
  instructions: 1,
  item: 0,
  items: 0,
  load_path: 1,
  map: 2,
  max_turns: 1,
  maybe_from: 1,
  maybe_from: 2,
  mcp_tools: 1,
  memory: 1,
  model: 1,
  operation: 1,
  operation: 2,
  output: 1,
  reduce: 2,
  result: 1,
  skill: 1,
  steps: 1,
  subagent: 1,
  subagent: 2,
  timeout: 1,
  tools: 1,
  value: 1,
  workflow: 1,
  workflow: 2
]

locals_without_parens = spark_locals_without_parens

[
  import_deps: [:spark],
  inputs: ["{mix,.formatter,.credo,.doctor}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  plugins: [Spark.Formatter],
  locals_without_parens: locals_without_parens,
  line_length: 120,
  export: [
    locals_without_parens: locals_without_parens
  ]
]
