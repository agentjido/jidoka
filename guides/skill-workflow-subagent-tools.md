# Skill, Workflow, And Subagent Tools

This guide explains three operation sources that share one spine: **skills**
contribute prompt instructions plus action-backed operations from a Jido.AI
skill manifest, **workflows** expose deterministic application code as one
model-callable operation, and **subagents** delegate a bounded task to a child
agent within a single turn. All three compile to `Jidoka.Agent.Spec.Operation`
entries and are routed through `Jidoka.Operation.Source`, so the turn loop
sees a single operation model. By the end you will know which entity to reach
for in each situation and how to test all three deterministically.

## When To Use This

- Use **skill** when you want a reusable bundle: prompt text plus the actions
  needed to honour that prompt. Skills are the right shape when the same
  capability ships to many agents and you want the prompt and tools to travel
  together.
- Use **workflow** when application-owned deterministic code should appear as
  one tool. Workflows hide multi-step deterministic logic from the model. See
  [Workflows](workflows.md) for the full workflow DSL.
- Use **subagent** when a bounded specialist should answer one nested
  question inside the current turn, with its own model, instructions, and
  tools, and return a structured result to the parent.
- Do **not** use **subagent** to transfer conversation ownership. That is a
  **handoff** and lives in [Handoffs](handoffs.md).
- If you are choosing between subagent and handoff, start with
  [Agent Orchestration](agent-orchestration.md).
- Do **not** use **workflow** for one-off code. A plain `Jidoka.Action`
  is simpler.

## Prerequisites

- A working Jidoka DSL agent. See [Getting Started](getting-started.md).
- For skills: `Jido.AI.Skill` (vendored under `jido_ai`) and any skill
  modules or `SKILL.md` files you want to load.
- No extra dependencies for workflows or subagents.
- The full workflow authoring reference lives in [Workflows](workflows.md).

## Quick Example

One DSL block can register all three sources for one agent:

```elixir
defmodule MyApp.MathWorkflow do
  use Jidoka.Workflow

  workflow do
    id :math_workflow
    description "Adds one and doubles the value."
    input Zoi.object(%{value: Zoi.integer()})
  end

  steps do
    function :calculate, {__MODULE__, :calculate, 2},
      input: %{value: input(:value)}
  end

  output from(:calculate)

  def calculate(%{value: value}, _context), do: {:ok, %{value: (value + 1) * 2}}
end

defmodule MyApp.EvidenceAgent do
  use Jidoka.Agent

  agent :evidence_agent do
    instructions "Answer with bounded evidence."
  end
end

defmodule MyApp.HelperAgent do
  use Jidoka.Agent

  agent :helper_agent do
    instructions "Use available tools before answering."
  end

  tools do
    skill MyApp.SupportPolicySkill
    workflow MyApp.MathWorkflow, as: :run_math, result: :structured
    subagent MyApp.EvidenceAgent, as: :evidence_specialist, result: :structured
  end
end
```

The compiled spec exposes one operation per skill action, one `run_math`
operation for the workflow, and one `evidence_specialist` operation for the
subagent.

## Concepts

```diagram
╭──────────────────────────────╮
│ tools do                     │
│   skill MySkill              │
│   workflow MyFlow, ...       │
│   subagent ChildAgent, ...   │
╰──────────────┬───────────────╯
               │ Tool-source compiler.operations!
               ▼
╭──────────────────────────────╮
│ Jidoka.Operation.Source.*    │
│  Skill -> JidoActions path   │
│  Workflow -> WorkflowSource  │
│  Subagent -> SubagentSource  │
╰──────────────┬───────────────╯
               │ normalize
               ▼
╭──────────────────────────────╮
│ Jidoka.Agent.Spec.Operation  │
│  metadata.source =           │
│   "skill" | "workflow"       │
│   | "subagent"               │
╰──────────────┬───────────────╯
               │ Jidoka.Operation.Source.compile
               ▼
╭──────────────────────────────╮
│ Routed runtime capability    │
│  intent.name -> source       │
╰──────────────────────────────╯
```

Three things are the same across all three sources:

1. **One operation per call site.** A workflow is always one operation. A
   subagent is always one operation. A skill is one operation per action the
   skill manifest publishes.
2. **Stable metadata.** Every operation tags `metadata.source` with the
   string `"skill"`, `"workflow"`, or `"subagent"`, plus `kind`, the
   underlying module, and a parameters schema when one is available.
3. **One capability per source.** `Jidoka.Operation.Source.compile/2` builds a
   router so the agent loop dispatches to the right source by operation name.

Differences worth keeping in mind:

- **Skill** validates references through `Jidoka.Skill.validate_ref/1`. Module
  references must implement `manifest/0`, `body/0`, and `actions/0`. String
  references must match the lowercase-with-hyphens skill name format.
- **Workflow** requires a module that `use Jidoka.Workflow`. Jidoka calls
  `definition/1` at compile time to capture the id, description, and
  parameters schema.
- **Subagent** requires a module that `use Jidoka.Agent`. The child agent is
  resolved at compile time, but its turn runs through the same harness as the
  parent's.

### Security / Trust Boundaries

- The DSL trusts skill, workflow, and subagent module references. Never
  derive them from user input. Resolve through an internal allowlist or
  registry first.
- `Jido.AI.Skill.Registry` loads `SKILL.md` files relative to the agent's
  source directory. The DSL never expands paths supplied by external input;
  it only expands paths from `load_path` entries inside the DSL.
- Subagent operations carry `forward_context:` policy. `:public` forwards the
  parent's public context to the child; `{:only, keys}` and `{:except, keys}`
  let you carve out what the child may see. Sensitive keys belong in the
  internal context and stay there by default.
- Workflow operations are deterministic application code. Treat them as the
  safe alternative to ad hoc tool integrations: the workflow module is the
  one place that touches external systems, and it can validate inputs before
  it does.
- None of these sources expose provider credentials. Subagents reach for
  credentials through the host environment, the same way the parent does.

## How To

### Step 1: Add A Skill For Reusable Prompt + Actions

A skill bundles instructions and action modules. Registering it contributes
both.

```elixir
defmodule MyApp.SupportPolicySkill do
  use Jido.AI.Skill,
    name: "support-policy",
    description: "Adds support policy lookup behavior.",
    allowed_tools: ["skill_policy_lookup"],
    actions: [MyApp.PolicyLookupAction],
    body: """
    # Support Policy

    Use skill_policy_lookup before answering policy questions.
    """
end

defmodule MyApp.SkillAgent do
  use Jidoka.Agent

  agent :skill_agent do
    instructions "Answer support questions with available capabilities."
  end

  tools do
    skill MyApp.SupportPolicySkill
  end
end
```

The compiled spec carries the skill body inside `spec.instructions` and one
`:skill` operation per action in the manifest.

### Step 2: Define A Deterministic Workflow

A workflow is one operation backed by deterministic steps you fully own. This
guide only shows how workflow modules compose with skills and subagents; the
full workflow DSL is covered in [Workflows](workflows.md).

```elixir
defmodule MyApp.RefundWorkflow do
  use Jidoka.Workflow

  workflow do
    id :process_refund
    description "Validates and queues a refund."
    input Zoi.object(%{order_id: Zoi.string()})
  end

  steps do
    function :queue_refund, {__MODULE__, :queue_refund, 2},
      input: %{order_id: input(:order_id)}
  end

  output from(:queue_refund)

  def queue_refund(%{order_id: order_id}, _context),
    do: {:ok, %{refund_id: "refund-#{order_id}", status: "queued"}}
end

tools do
  workflow MyApp.RefundWorkflow,
    as: :run_refund,
    forward_context: {:only, [:actor, :tenant]},
    result: :structured
end
```

`result: :output` returns the workflow output directly. `result: :structured`
wraps it with workflow and operation metadata so the parent turn can inspect
where the value came from.

### Step 3: Delegate To A Subagent For One Task

A subagent is one bounded child turn. The parent decides when to call it; the
child returns a structured result.

```elixir
defmodule MyApp.EvidenceAgent do
  use Jidoka.Agent

  agent :evidence_agent do
    instructions "Return bounded evidence for a single question."
  end
end

defmodule MyApp.ParentAgent do
  use Jidoka.Agent

  agent :parent_agent do
    instructions "Delegate evidence collection before answering."
  end

  tools do
    subagent MyApp.EvidenceAgent,
      as: :evidence_specialist,
      timeout: 15_000,
      forward_context: {:only, [:tenant]},
      result: :structured
  end
end
```

The parent's prompt sees one tool, `evidence_specialist`. The child's turn
runs through the same harness, with its own loop budget and timeout.

### Step 4: Inspect The Compiled Operations

The spec metadata documents what was registered. Use it to confirm sources
are configured the way you expect.

```elixir
spec = MyApp.HelperAgent.spec()

Enum.map(spec.operations, & &1.name)
#=> ["skill_policy_lookup", "run_math", "evidence_specialist"]

spec.metadata["tool_sources"]
#=> [
#  %{"source" => "skill", "name" => "support-policy"},
#  %{"source" => "workflow", "name" => "run_math", "workflow" => "math_workflow"},
#  %{"source" => "subagent", "name" => "evidence_specialist"}
#]
```

### Step 5: Choose Between Subagent And Handoff

Subagents and handoffs look similar but solve different problems:

| Concern | Subagent | Handoff |
| --- | --- | --- |
| Lifetime | One bounded call within the parent's turn | Future turns for the conversation |
| Ownership | Parent keeps ownership; child returns a result | Ownership transfers to the target agent |
| DSL entity | `subagent ChildAgent, as: ...` | `handoff TargetAgent, as: ...` |
| Idempotency | `:idempotent` by default | `:unsafe_once` |
| When to use | "Answer this side question for me" | "From now on, billing owns this thread" |

When in doubt, ask whether the parent should still own the conversation
after the call returns. If yes, use a subagent. See [Handoffs](handoffs.md)
for the handoff path, or [Agent Orchestration](agent-orchestration.md) for the
full comparison and dispatcher pattern.

## Common Patterns

- **Pair a skill with a workflow.** The skill teaches the prompt how to call
  a deterministic capability; the workflow implements it. The agent author
  composes both with two DSL lines.
- **Pin subagent results to `:structured` for downstream chaining.** Plain
  text results are convenient for prompts but lose machine-readable shape.
- **Use `forward_context: {:only, ...}`** to make subagent context a
  deliberate contract instead of an accident.
- **Treat workflow modules as bounded contexts.** One workflow per business
  operation is easier to test and review than a giant module with branching.

## Testing

All three sources use the same fake-LLM pattern as
[Getting Started](getting-started.md). The interesting differences are at the
operation boundary:

```elixir
defmodule MyApp.HelperAgentTest do
  use ExUnit.Case, async: true

  test "workflow round trip" do
    llm = fn _intent, journal, _ctx ->
      llm_calls = Enum.count(journal.results, fn {_id, r} -> r.kind == :llm end)

      case llm_calls do
        0 -> {:ok, %{type: :operation, name: "run_math", arguments: %{"value" => 5}}}
        1 -> {:ok, %{type: :final, content: "The result is 12."}}
      end
    end

    assert {:ok, result} =
             Jidoka.turn(MyApp.HelperAgent, "Compute next.", llm: llm)

    assert result.content =~ "12"
  end
end
```

Subagent tests use the same shape; the inner agent's prompt is exercised by
the same fake LLM through pattern matching on `payload.agent_id`. See
`test/jidoka/subagent_test.exs` for the canonical
example. Skill tests live in
`test/jidoka/skill_test.exs`; workflow tests in
`test/jidoka/workflow_test.exs`.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, {:invalid_skill, ref, reason}}` at compile time | The skill module or name failed validation. | Confirm the module exports `manifest/0`, `body/0`, and `actions/0`, or use a hyphenated string name registered through `Jido.AI.Skill.Registry`. |
| `{:error, {:invalid_workflow_module, module, reason}}` | The workflow module is missing a valid callback or DSL definition. | Use `workflow do id :snake_case_id ... end`, add `steps do ... end`, and declare `output from(:step)`. |
| `{:error, {:duplicate_operation_source_name, name}}` | Two sources produced the same operation name. | Use `as:` overrides on workflow or subagent, or split the agent. |
| Subagent times out | `timeout:` is too small for the child's tool loop. | Raise `timeout:` or simplify the child. The default is `30_000` ms. |
| Skill prompt does not appear in `spec.instructions` | The skill module failed to resolve; check `Jidoka.Skill.prompt/2` for the same refs. | Add a `load_path` entry or register the skill at the application layer. |

## Reference

Key modules touched in this guide:

- [`Jidoka.Operation.Source`](`Jidoka.Operation.Source`) - behaviour and
  compiler that all three sources share.
- [`Jidoka.Skill`](`Jidoka.Skill`) - skill validation, action extraction,
  prompt rendering, and metadata.
- [`Jidoka.Workflow`](`Jidoka.Workflow`) - behaviour for deterministic
  workflow modules.
- [`Jidoka.Operation.Source.Workflow`](`Jidoka.Operation.Source.Workflow`) -
  workflow source struct and capability.
- [`Jidoka.Operation.Source.Subagent`](`Jidoka.Operation.Source.Subagent`) -
  subagent source struct and capability.
- [`Jidoka.Agent.Spec.Operation`](`Jidoka.Agent.Spec.Operation`) - the
  normalized operation entry produced by every source.

## Related Guides

- [Getting Started](getting-started.md) - the smallest DSL agent end to end.
- [Workflows](workflows.md) - full workflow DSL, refs, runtime behavior, and
  testing.
- [Handoffs](handoffs.md) - conversation ownership transfer; the partner
  pattern to subagents.
- [AshJido Resources](ash-jido.md) - a sibling source for Ash-backed tools.
- [MCP Tools](mcp-tools.md) - a sibling source for remote MCP servers.
- [Browser Tools](browser-tools.md) - a sibling source for constrained
  browsing.
