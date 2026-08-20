---
id: D08-R2
title: Require one customer-search selector
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P3
impact: medium
confidence: high
effort: low
blast_radius: low
dependencies: []
---

# Require one customer-search selector

## Objective

Remove hidden precedence from the Lua-tools customer search action.

## Evidence

- `showcase/lib/jidoka_showcase/lua_tools_agent/actions/search_customers.ex:8-20` declares six nullable selectors.
- `showcase/lib/jidoka_showcase/lua_tools_agent/actions/search_customers.ex:34-66` selects the first nonempty selector.

## Current problem

Supplying two selectors silently selects one based on code order. The caller cannot know which requested search is used.

## Proposed representation and invariant

Use one explicit selector variant, or keep the current fields but reject zero and multiple nonempty fields.

Invariant: one request specifies exactly one customer-search mode.

## Smallest credible scope

- `showcase/lib/jidoka_showcase/lua_tools_agent/actions/search_customers.ex`
- Action schema and tests

The public showcase action input changes. No persisted data changes.

## Risks and migration

Current multi-field callers will receive a typed validation error. If compatibility is required, accept old single-field input through a normalizer.

## Validation

Run existing Lua-tools action tests.

Add these cases:

- Each selector alone -> expected search result.
- No selector -> validation error.
- Two selectors -> validation error that names both fields.

## Acceptance criteria

- No request can rely on field-order precedence.
- Each valid selector keeps its current search behavior.

## Out of scope

- Search-ranking or substring-matching changes.
