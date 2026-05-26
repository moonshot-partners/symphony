# Symphony eval harness

`mix symphony.eval` replays 10 frozen ticket scenarios calibrated against real
production data from Hetzner (`/opt/symphony/state/decisions.jsonl` +
`runs.jsonl`) and records structural observations. Used in CI to detect
regressions in the orchestrator's classification routing.

## Quickstart

```bash
cd elixir
mix symphony.eval --record --output evals/results/baseline.jsonl
mix symphony.eval --diff   --baseline evals/results/baseline.jsonl \
                           --candidate evals/results/candidate.jsonl
```

Exit code 0 means all invariants are intact. Nonzero means at least one fixture
diverged.

## Fixture schema

Each `.exs` file evaluates to a map with four keys:

- `:issue` — Linear ticket snapshot (identifier, state, has_pr_attachment, etc.)
- `:events` — ordered list of `decisions.jsonl` events using the production
  vocabulary (`:reconcile_decision`, `:workpad_pr_sync_route`,
  `:pr_reengagement_skip_no_pr`, `:pr_reengagement_skip_no_critical`,
  `:pr_reengagement_fetch_error`)
- `:run` — one row from `runs.jsonl` (turns, outcome, tokens_in/out, retries,
  pr_url)
- `:expected` — outputs the Runner must reproduce (final_state, gate_verdicts,
  turn_count, error_class, pr_outcome, decision_event_count)

## Invariants

For each fixture, the diff engine checks:

1. `final_state` — exact string match
2. `gate_verdicts` — exact ordered list match
3. `turn_count` — within +/-1 (configurable)
4. `error_class` — exact match (`nil`, `:ci_red`, `:qa_blocked`,
   `:not_routable`, `:parked`, `:canceled`, `:no_pr`, `:no_critical`,
   `:fetch_error`)
5. `pr_outcome` — exact match (`pr_open`, `no_pr`)
6. `decision_event_count` — within +/-20% (configurable)

## The 10 calibrated fixtures

Each fixture is derived from a real SODEV ticket in Hetzner production state.
The `events` list is the production event sequence; the `run` map is the
matched row from `runs.jsonl`.

| ID | SODEV | Scenario | error_class | final_state |
|----|-------|----------|-------------|-------------|
| `01_sodev_843_default_complete` | 843 | clean default complete | `nil` | In Code Review |
| `02_sodev_824_final_default_complete` | 824 | pr cleared after iterations | `nil` | In Code Review |
| `03_sodev_824_qa_blocked` | 824 | agent self-reported qa block | `:qa_blocked` | On Hold / Blocked |
| `04_sodev_892_ci_red_scope` | 892 | scope-discipline plus review red | `:ci_red` | On Hold / Blocked |
| `05_sodev_824_ci_red_review_qa` | 824 | review + qa-evidence red | `:ci_red` | On Hold / Blocked |
| `06_sodev_824_ci_red_double_review` | 824 | two reviews + qa-evidence red | `:ci_red` | On Hold / Blocked |
| `07_sodev_860_ci_red_heavy` | 860 | heaviest ci red on record (7 checks) | `:ci_red` | On Hold / Blocked |
| `08_sodev_904_not_routable` | 904 | ticket parked back to backlog | `:not_routable` | Backlog |
| `09_sodev_860_skip_no_critical` | 860 | pr re-engagement skipped no critical | `:no_critical` | In Development |
| `10_sodev_146_skip_no_pr` | 146 | ticket with no pr attached | `:no_pr` | In Development |

## Adding a fixture

1. SSH to Hetzner: `ssh -i ~/.ssh/symphony_ci_hetzner root@46.62.226.192`
2. Pull `/opt/symphony/state/decisions.jsonl` and `runs.jsonl*`
3. Pick a SODEV ticket whose flow exemplifies the new scenario
4. Create `evals/dataset/<NN>_sodev_<id>_<short_name>.exs` with the four-key
   schema, copying the real event sequence and runs row
5. Re-record baseline:
   `cd elixir && mix symphony.eval --record --output evals/results/baseline.jsonl --dataset ../evals/dataset`
6. Commit the new fixture and the updated baseline

## What this harness does NOT test

- Real Claude SDK behavior (LLM responses are not exercised)
- Real Linear/GH API integration (no network calls)
- Workspace setup, git clone, npm install reliability
- Agent prompt regressions (those need a separate eval — see SYM-39)

This harness is a regression detector for the orchestrator's decision pipeline,
not an end to end eval. It runs in seconds and costs nothing.

## v1 architecture note

The current Runner is a pure-function classifier over each fixture's `events`
sequence and reads `turn_count` / `pr_outcome` from the matched `run` row. It
does NOT spawn the orchestrator GenServer. Follow-up tickets may upgrade Runner
to drive `TestHooks.reconcile_issue_states_for_test` for higher fidelity, but
v1 is intentionally fast and deterministic.
