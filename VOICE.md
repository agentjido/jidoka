# Jidoka Docs Voice

Jidoka docs are for developers trying to build agents. Write for the next
thing they need to do.

## Principles

- Be direct. Start with the outcome, then show the code.
- Prefer real LLM usage in user guides. Use deterministic fake LLMs only in
  testing, contributor, or internals guides.
- Use the shortest valid DSL. Let defaults carry model generation, controls,
  memory, tracing, and sessions until the guide is specifically about them.
- Explain architecture only when it changes a developer decision. Most readers
  do not care about internals; they care that the agent runs, calls tools, can
  be inspected, and can be resumed.
- Treat Jido, ReqLLM, Runic, Zoi, and Spark as implementation strengths, not
  onboarding hurdles. Introduce them when the reader needs the concept.
- Avoid release-history language. This is Jidoka, not Jidoka V2.

## Style

- Terse, concrete, explanatory.
- Use imperative section names: `Define An Agent`, `Run A Turn`,
  `Add A Tool`, `Inspect The Prompt`.
- Cut filler phrases: "This guide explains", "By the end", "intentionally",
  "canonical", "stable", "thin", "surface", "Runic spine", unless the word
  carries a real technical distinction.
- Do not use internal architecture labels in user-facing guides. Say "runtime",
  "turn", "workflow", "tool call", or "resume" instead. Save `Runic`, harness
  internals, effect interpreters, and workflow phase names for internals guides.
- Prefer one complete example over several partial examples.
- Keep examples copy-pasteable. Do not include optional settings unless the
  guide is teaching those settings.
- Use `chat/3` for product-facing examples. Use `turn/3` when the guide needs
  the full result, journal, events, snapshot, or structured value.

## Guide Shape

Most guides should follow this order:

1. What you will build or configure.
2. Minimal working code.
3. How to run it with a real provider.
4. What the key data or runtime boundary means.
5. Common mistakes and fixes.
6. Links to deeper guides.

Testing guides invert this:

1. Deterministic fake LLM.
2. Injected operation capability.
3. Golden/integration coverage.
4. Optional live-provider coverage.

## Examples

User-facing:

```elixir
{:ok, text} = MyAgent.chat("What should I do next?")
```

Testing-facing:

```elixir
llm = fn _intent, _journal ->
  {:ok, %{type: :final, content: "ok"}}
end

{:ok, result} = Jidoka.turn(MyAgent, "test input", llm: llm)
```

The live path is the default story. The fake path is the testing story.
