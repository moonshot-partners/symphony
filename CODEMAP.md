# Symphony CODEMAP

Single-page navigation index. Goal: any AI agent (or human) finds the right file in &lt;30 seconds.

## "I want to change X → touch Y"

| Intent | File(s) |
|---|---|
| Change polling cadence | `elixir/WORKFLOW.md` `polling.interval_ms` |
| Add/change tracker state | `elixir/WORKFLOW.md` `tracker.active_states` / `terminal_states` |
| Add a new workflow gate | `elixir/lib/symphony_elixir/gate_*.ex` + `orchestrator/gate_*_trigger.ex` |
| Change agent prompt | `elixir/WORKFLOW.md` body (Liquid template) |
| Change workspace lifecycle | `elixir/lib/symphony_elixir/workspace.ex` + WORKFLOW `hooks.after_create` |
| Add tracker adapter (Jira, GitHub) | `elixir/lib/symphony_elixir/tracker/` + `tracker.ex` behaviour |
| Touch Linear API | `elixir/lib/symphony_elixir/linear/client.ex` |
| Change orchestrator dispatch policy | `elixir/lib/symphony_elixir/orchestrator/dispatch_gate.ex` + `slot_policy.ex` |
| Change reconciliation logic | `elixir/lib/symphony_elixir/orchestrator/reconcile.ex` |
| Change retry policy | `elixir/lib/symphony_elixir/orchestrator/retry_plan.ex` + `retry_attempts.ex` |
| Token metrics | `elixir/lib/symphony_elixir/orchestrator/token_metrics.ex` |
| Workpad (Linear comment sync) | `elixir/lib/symphony_elixir/workpad.ex` |
| QA evidence upload | `elixir/lib/symphony_elixir/qa_evidence.ex` |
| Agent runner (claude shim) | `elixir/lib/symphony_elixir/agent_runner.ex` + `agent/app_server.ex` |
| Python shim | `elixir/priv/agent_shim/src/symphony_agent_shim/` |
| Run ledger / forensics | `elixir/lib/symphony_elixir/run_ledger.ex` + `run_ledger/forensics.ex` |
| Reports (SYMPHONY_RUNS.md) | `elixir/lib/mix/tasks/runs.report.ex` |
| Deploy | `.github/workflows/deploy.yml` + `scripts/deploy.sh` (VPS) |
| Quality gate (CI) | `.github/workflows/symphony-agent-gate.reusable.yml` |
| Consultant onboarding | `elixir/CONSULTANT-GUIDE.md` |
| Service contract | `SPEC.md` |

## State files (runtime, `/opt/symphony/state/`)

| File | Owner | Purpose |
|---|---|---|
| `workpads.json` | `Orchestrator` | issue_id → Linear workpad comment id |
| `status.json` | `Orchestrator.StatusFile` | snapshot for ops |
| `drain.flag` | `Orchestrator` | sentinel: stop accepting new work |
| `runs.jsonl` | `RunLedger` | one line per terminated run (append-only) |
| `runs/<ticket_id>.md` | `RunLedger.Forensics` | per-ticket attempt history |
| `SYMPHONY_RUNS.md` | `mix runs.report` | rolling narrative summary |

## Architectural layers (per `SPEC.md` §3.2)

1. Policy — `WORKFLOW.md` (prompt + rules)
2. Configuration — `lib/symphony_elixir/config*` (typed getters)
3. Coordination — `lib/symphony_elixir/orchestrator*` (poll, dispatch, reconcile, retry)
4. Execution — `lib/symphony_elixir/workspace.ex` + `agent_runner.ex` + `priv/agent_shim/`
5. Integration — `lib/symphony_elixir/linear/` + `tracker.ex`
6. Observability — `lib/symphony_elixir/log_file.ex` + `run_ledger.ex` + status file

## Operational secrets

See `elixir/CONSULTANT-GUIDE.md` §2.
