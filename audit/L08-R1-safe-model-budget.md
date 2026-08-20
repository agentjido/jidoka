---
id: L08-R1
title: Budget prompts for every declared model candidate
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P1
impact: high
confidence: medium-high
effort: medium
blast_radius: high
dependencies: []
---

# Budget prompts for every declared model candidate

## Objective

Ensure prompt preparation fits the model that receives the prompt.

## Evidence

- `lib/jidoka/context_window/policy.ex:50-119` budgets against the base model.
- `lib/jidoka/model_policy.ex:167-191` selects a model after preparation.
- `lib/jidoka/turn/plan.ex:41-48` holds model-policy input.
- `lib/jidoka/runtime/spine/steps.ex:28-44` prepares before provider selection.

## Current problem

A smaller fallback or selected model can receive a prompt that fits only the base
model. This causes late provider failure.

## Proposed representation and invariant

Normalize a finite declared candidate-model set in the plan. Compute the input budget
from its smallest capacity. A selector result must be in that set.

## Smallest credible scope

- Update turn plan, model policy, context-window policy, and prompt preparation.
- Update provider-model-policy tests.
- Define strict behavior for selectors that return undeclared models.

## Risks and migration

Prompts can compact earlier. Custom selectors can fail if they return undeclared
models. Use a documented strict setting or versioned default.

## Validation

- Run existing context-window, model-policy, and provider policy tests.
- Input: primary and fallback with different limits. Expected: lower limit is used.
- Input: selector returns undeclared model. Expected: typed policy error.
- Input: every declared route. Expected: prompt fits input capacity.

## Acceptance criteria

- Preparation uses the minimum finite declared candidate budget.
- Strict selectors cannot return undeclared models.
- Fallback behavior is deterministic and documented.

## Out of scope

Do not change provider token counting or add dynamic model discovery.
