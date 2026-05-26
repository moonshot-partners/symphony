# Symphony eval harness

`mix symphony.eval` replays 10 frozen ticket scenarios through the orchestrator's
in-process reconcile pipeline and records structural observations. Used in CI to
detect regressions in gate enforcement, state transitions, and error
classification.

## Quickstart

```bash
cd elixir
mix symphony.eval --record --output evals/results/baseline.jsonl
mix symphony.eval --diff   --baseline evals/results/baseline.jsonl \
                           --candidate evals/results/candidate.jsonl
```

Exit code 0 means all invariants are intact. Nonzero means at least one fixture
diverged.

## Invariants

For each fixture, the diff engine checks:

1. `final_state` — exact string match
2. `gate_verdicts` — exact ordered list match
3. `turn_count` — within +/-1 (configurable)
4. `error_class` — exact match (`nil`, `:gate_c_reject`, `:gate_d_reject`, `:ci_red`, `:qa_blocked`, `:conflict_disclosure_reject`, `:exhaust`)
5. `pr_outcome` — exact match (`merged`, `closed_unmerged`, `pr_open`, `no_pr`)
6. `decision_event_count` — within +/-20% (configurable)

## The 10 golden fixtures

| ID | Scenario | error_class | pr_outcome | final_state |
|----|----------|-------------|------------|-------------|
| `01_happy_path` | Agent ships PR cleanly, CI green, review clean | `nil` | `merged` | In Code Review |
| `02_ci_red` | CI fails after PR open | `:ci_red` | `pr_open` | On Hold |
| `03_qa_blocked` | Playwright selector miss, QA blocked | `:qa_blocked` | `pr_open` | On Hold |
| `04_gate_c_reject` | Agent skipped `## AC Extracted` in turn 1 | `:gate_c_reject` | `no_pr` | On Hold |
| `05_gate_d_reject` | Agent claimed `verified` without evidence | `:gate_d_reject` | `pr_open` | On Hold |
| `06_conflict_disclosure_reject` | Agent touched files outside `## Files` | `:conflict_disclosure_reject` | `pr_open` | On Hold |
| `07_exhaust` | Agent hit turn cap with green CI | `:exhaust` | `pr_open` | In Code Review |
| `08_blocked_graceful_exit` | `qa_blocked?` short-circuits via SYM-13 path | `:qa_blocked` | `pr_open` | On Hold |
| `09_k1_reengagement` | claude-pr-review request_changes triggers SYM-16 K=1 | `nil` | `merged` | In Code Review |
| `10_pr_continuation` | Re-dispatch with `has_pr_attachment` continues same branch | `nil` | `merged` | In Code Review |

## Adding a fixture

1. Create `evals/dataset/<NN>_<short_name>.exs` with the schema (see existing fixtures).
2. Re-record baseline: `cd elixir && mix symphony.eval --record --output evals/results/baseline.jsonl --dataset ../evals/dataset`.
3. Commit the new fixture and the updated baseline.

## What this harness does NOT test

- Real Claude SDK behavior (LLM responses are not exercised)
- Real Linear/GH API integration (no network calls)
- Workspace setup, git clone, npm install reliability
- Agent prompt regressions (those need a separate eval — see SYM-39)

This harness is a regression detector for the orchestrator's decision pipeline,
not an end to end eval. It runs in seconds and costs nothing.

## v1 architecture note

The current Runner is a pure-function classifier over each fixture's `events`
sequence. It does NOT spawn the orchestrator GenServer. Follow-up tickets may
upgrade Runner to drive `TestHooks.reconcile_issue_states_for_test` for higher
fidelity, but v1 is intentionally fast and deterministic.
