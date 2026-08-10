import Config

config :jidoka,
  default_model: "openai:gpt-4o-mini",
  default_max_model_turns: 8,
  default_turn_timeout_ms: 30_000,
  default_generation: %{
    params: %{
      temperature: 0.0,
      max_tokens: 500
    }
  }

config :req_llm, load_dotenv: false

if config_env() == :dev do
  config :git_ops,
    mix_project: Jidoka.MixProject,
    changelog_file: "CHANGELOG.md",
    repository_url: "https://github.com/agentjido/jidoka",
    manage_mix_version?: true,
    version_tag_prefix: "v",
    types: [
      feat: [header: "Features"],
      fix: [header: "Bug Fixes"],
      perf: [header: "Performance"],
      refactor: [header: "Refactoring"],
      docs: [hidden?: true],
      test: [hidden?: true],
      deps: [hidden?: true],
      chore: [hidden?: true],
      ci: [hidden?: true]
    ]
end

config :spark, :formatter,
  remove_parens?: true,
  "Jidoka.Agent": [
    type: Jidoka.Agent.SparkDsl,
    section_order: [:jidoka, :tools, :controls]
  ]
