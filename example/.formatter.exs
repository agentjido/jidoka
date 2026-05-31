[
  import_deps: [:phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  locals_without_parens: [
    action: 1,
    agent: 1,
    agent: 2,
    ash_resource: 1,
    ash_resource: 2,
    browser: 1,
    browser: 2,
    catalog: 1,
    catalog: 2,
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
  inputs: [
    "*.{ex,exs}",
    "{config,lib}/**/*.{ex,exs,heex}"
  ]
]
