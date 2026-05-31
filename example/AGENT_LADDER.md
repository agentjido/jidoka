# Agent Ladder

The example app should teach Jidoka by adding one meaningful capability at a
time. Each agent is a use case first, then a feature showcase.

## Principles

- Keep the first screen runnable with a real LLM and a single prompt.
- Prefer visible behavior over abstract explanation.
- Add controls early so developers see that agents are bounded by default.
- Put the guide text near the agent module, then render it in the LiveView.
- Keep examples small enough to copy into a new app.

## Rungs

### 1. Support Agent

Status: implemented.

Shows a supervised Jidoka agent with one local `Jidoka.Action`, a durable
session id, a reset button, activity projection, source view, and basic controls.

Primary features:

- `agent do`
- string `instructions`
- `generation`
- `controls do max_turns ... timeout ... end`
- `tools do action ... end`
- supervised Jido process
- LiveView AgentView projection

### 2. Research Agent

Status: implemented.

Adds browser-backed tools and a stronger evidence loop. The agent searches,
reads public pages, then answers with links.

Primary features:

- `tools do browser :public_web, mode: :read_only end`
- `search_web`
- `read_page`
- tighter run controls for multi-tool turns
- missing-credential handling for `BRAVE_SEARCH_API_KEY`

### 3. Interview Agent

Status: planned.

Guides a user through a short sequence of questions and turns the answers into a
summary. This should demonstrate sessions and progressive context without adding
external tools.

Primary features:

- multi-turn session behavior
- lightweight state inspection
- clear stopping condition
- controls that prevent endless interviewing

### 4. Triage Agent

Status: planned.

Classifies an inbound issue, routes it to a category, and produces a structured
recommendation. This should introduce output shape and validation.

Primary features:

- `controls.output`
- structured result projection
- validation failures surfaced in the UI

### 5. Approval Agent

Status: planned.

Prepares a draft action but pauses for human approval before committing it. This
is the right place to demonstrate pending effects and human-in-the-loop controls.

Primary features:

- pending effects
- approve/reject UI
- resumable agent turn

### 6. Analyst Agent

Status: planned.

Combines multiple tools and local data to answer a richer operational question.
This can introduce tool catalogs once the first five examples are stable.

Primary features:

- multiple tool sources
- richer activity timeline
- clearer error and retry surfaces

### 7. Workflow Agent

Status: planned.

Shows when to move from a single agent loop to an explicit workflow. This should
stay grounded in the Runic spine rather than becoming a general workflow demo.

Primary features:

- explicit workflow phases
- hibernate/resume checkpoints
- inspection of workflow state

## Current Focus

The next example should be the Interview Agent. It adds obvious user value,
exercises real sessions, and gives controls a more visible role without needing
new external services.
