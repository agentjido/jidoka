[
  import_deps: [:phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  locals_without_parens: [
    action: 1,
    agent: 1,
    agent: 2,
    generation: 1,
    instructions: 1,
    tools: 1
  ],
  inputs: [
    "*.{ex,exs}",
    "{config,lib}/**/*.{ex,exs,heex}"
  ]
]
