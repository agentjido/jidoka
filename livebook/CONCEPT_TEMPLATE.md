# Jidoka Concept Livebook Template

Use this structure for each concept notebook in `livebook/`.

## Notebook Contract

- File name: `NN_concept_name.livemd`.
- Title: `# Jidoka: Concept Name`.
- Default path: provider-free and deterministic.
- Optional live-provider cells must be gated by env vars.
- Use the standard Git-based `Mix.install/2` pattern until Jidoka ships on Hex.
  Include the commented Hex replacement line.
- Configure `:model_aliases` in the `Mix.install/2` config block so `model
  :fast` resolves consistently in every notebook.
- Prefer one concept per notebook. Link to the next concept instead of building a
  kitchen sink.
- Do not put broad package explanations in every notebook. Keep each notebook
  focused on what the reader can run and inspect.

## Teaching Flow

1. **What You Will Learn**
   - One paragraph.
   - Three bullet takeaways max.

2. **Setup**
   - `Mix.install/2` cell.
   - Any aliases or demo data needed by later cells.

3. **Minimal Code**
   - Define the smallest useful agent, action, control, workflow, or session.
   - Avoid production ceremony unless the concept requires it.

4. **Inspect The Surface**
   - Show generated IDs, tools, result contracts, schedules, or controls.
   - Use public helpers only.

5. **Run Provider-Free**
   - Prove the concept without model credentials.
   - Prefer deterministic actions, direct parsing, manual schedules, or an input
     control that interrupts before the provider call.

6. **Debug It**
   - Show request summaries, traces, AgentView snapshots, or Kino helpers.
   - Assert on structured data, not log text.

7. **Optional Live Turn**
   - Gate with `RUN_JIDOKA_LIVEBOOK_LIVE=1`.
   - Mention the provider env var in prose.
   - Keep assertions shape-oriented.

8. **What Changed**
   - Briefly state what Jidoka owned and what the host app still owns.

9. **Next**
   - Link to the next concept notebook.

## Cell Quality Rules

- Every code cell should be safe to reevaluate.
- Avoid hidden dependency on prior notebook state unless the previous cell
  defines the visible concept being taught.
- Use short, concept-shaped module names such as `Demo.Assistant` or
  `SupportDesk.Agent`. Avoid long teaching-only prefixes.
- Keep context maps small and concrete.
- Prefer `Jidoka.session/3` and `Jidoka.chat/3` for beginner-facing turns.
- Use `Jidoka.format_error/1` when printing errors.
- Do not expose raw secrets, tokens, or provider payloads.
