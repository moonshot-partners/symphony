# Agent exhaustion modes — diagnosis and detection

SYM-33 diagnose-first deliverable. Records what "the agent ran out" actually
means in practice, what evidence proves or disproves each hypothesis, and
where the existing telemetry classifies each mode today.

María's report (2026-05-20 SOs Daily): *"of the times I tried, one time the
tokens ran out, another time the memory ran out, several times the memory ran
out — I couldn't wait."*

The four hypothesized exhaustion modes from the SYM-33 ticket plus one
additional mode discovered while diagnosing.

## 1. Anthropic context window — input tokens approach the model cap

**Detection.** `runs.jsonl` records `tokens_in` and `tokens_out` per
terminated turn. A run nearing or exceeding the per-turn input cap surfaces
either an API error (recorded with `outcome=no_pr` and tokens recorded as 0)
or a turn whose reply is short/incoherent (recorded with normal outcome but
visibly bad output).

**30-day evidence.** Highest observed `tokens_out` in
`/opt/symphony/state/runs.jsonl*` is **76253** (SODEV-802, 2026-05-20 14:37,
2 turns, completed `pr_open`). All other runs sit well below this. No turn
recorded an API error attributable to context length, and no turn produced
zero tokens after a successful workspace clone.

**Verdict.** Not observed. The context window is not the bottleneck today.
The dominant scoping fix path (SYM-2 plan grounding, shipped 2026-05-21)
already trims pre-discovery prompt input.

## 2. Container / process OOM kill

**Detection.** Linux OOM kill of the shim process surfaces as
`{:port_exit, 137}` from the Python shim and as an `oom-killer` line in
`dmesg` / `journalctl -k`. Symphony's orchestrator records this as
`outcome=no_pr` with `tokens_total=0` and a parent `[error] Agent task
exited` line in the systemd journal.

**30-day evidence.** `journalctl -k --since "2026-05-19"` returned zero
matches for `oom`, `killed`, `out of memory`, or `memory cgroup`. The
Hetzner host has 30 GiB RAM with 24 GiB free at steady state and no swap
pressure. Symphony does not run agents in Docker on this host — the shim is
a Python venv invoked directly, so no per-container cgroup limit applies.

**Verdict.** Not observed in the 30-day persistent journal. Host has
ample headroom.

## 3. Turn cap exhaustion — `agent.max_turns` ceiling

**Detection.** `runs.jsonl` `turns` field equals the configured
`agent.max_turns` in `WORKFLOW.md` (currently 25). The agent may or may not
have opened a PR before the cap; if it did, the outcome is `pr_open` and the
run looks superficially fine, but the slow progress per turn is visible to
anyone watching the workpad.

**30-day evidence.** One observed hit: SODEV-840 on 2026-05-20 14:17 burned
exactly 25 turns and finished with `outcome=pr_open` (PR #570). The full
turn budget was consumed in a single dispatch. From an operator's
perspective this looks like the agent "running out" — turns tick by slowly
and the workpad goes quiet.

**Verdict.** Observed. Already mitigated by SYM-13 (graceful BLOCKED exit,
shipped 2026-05-23 PR #161): `TurnSoftCap.exhaust_target/2` now routes
green-CI exhaust to `on_exhaust_state` ("In Code Review") instead of the
reject path, and SYM-22 (preemptive completion at 80%) is the next planned
upgrade.

## 4. `claude-agent-sdk` read timeout

**Detection.** A turn exceeds `agent_runtime.read_timeout_ms`. The shim
exits cleanly (`{:port_exit, 0}`) with a stderr line "read timed out
after Xms".

**30-day evidence.** Zero `read timed out` lines in the journal. Default
`read_timeout_ms` is 60000 in `WORKFLOW.schools-out.md`; the
`feedback_claude_sdk_first_turn_timeout.md` memory documents 120000 as the
correct first-turn value but the live WORKFLOW currently sets 60000 — this
gap is a separate config-hygiene item, not a María-observable exhaustion.

**Verdict.** Not observed.

## 5. Workspace-hook retry loop (newly identified)

**Detection.** `journalctl -u symphony` shows a `workspace_hook_failed`
error from `AgentRunner.run/3` with a non-zero exit code (typically 128 for
git) and a stderr snippet. The orchestrator retries with backoff (10s, 20s,
…) up to its retry cap. Each failure writes a `runs.jsonl` row with
`outcome=no_pr` and `tokens_*=0`.

**30-day evidence.** On 2026-05-20 01:22-01:23 UTC, both SODEV-775 and
SODEV-435 hit `Cloning into '.'... fatal: could not read Username for
'https://github.com': No such device or address` three times in succession
across a ~90s window. From the operator's perspective the agent looked
stuck — no progress, no PR, repeated retries with no visible advance. This
matches María's "several times the memory ran out" phrasing more closely
than any of the original four buckets.

**Verdict.** Observed and dominant for that day's failures. Root cause is
GitHub-auth-not-configured at the shim subprocess level, not memory. The
operator-visible symptom is identical to exhaustion ("agent stuck, no
progress, never finishes"), which is why María categorized it that way.

## Per-bucket telemetry summary

The existing `runs.jsonl` schema already differentiates buckets 1, 3, and 5
without manual journal reading:

| Bucket | `outcome` | `turns` | `tokens_total` | Distinguishing field |
|--------|-----------|---------|----------------|----------------------|
| 1 context | `no_pr` | small | 0 or low | API error in journal |
| 2 OOM | `no_pr` | varies | 0 | `oom-killer` in `journalctl -k` |
| 3 turn cap | `pr_open` or `no_pr` | == `max_turns` | normal | none — outcome looks fine |
| 4 read timeout | `no_pr` | small | low | `read timed out` in journal |
| 5 hook retry | `no_pr` | 0 or 1 | 0 | `workspace_hook_failed` in journal |

**Gap.** The `outcome` label collapses buckets 1/2/4/5 into the single
`no_pr` value. Distinguishing among them still requires the journal.
Closing this gap is a YAGNI candidate — wait for a second María-style
report where the journal lookup is the bottleneck before adding an
`exhaustion_bucket` field.

## Source quotes from the 30-day evidence pull

* SODEV-840 turn-cap hit:
  `{"tokens":23909,"ticket":"SODEV-840","turns":25,"outcome":"pr_open",
  "recorded_at":"2026-05-20T14:17:33.236980Z"}`
* SODEV-775 workspace-hook retry (excerpt):
  `[error] Agent run failed for issue_id=964c440d-... issue_identifier=
  SODEV-775: {:workspace_hook_failed, "repos", 128, "Cloning into '.'...\n
  fatal: could not read Username for 'https://github.com': No such device
  or address\n"}`
* SODEV-802 highest output-token run:
  `{"tokens":76253,"ticket":"SODEV-802","turns":2,"outcome":"pr_open",
  "recorded_at":"2026-05-20T14:37:37.888017Z"}`

## What did not land in this ticket

* No speculative code fix (ticket constraint).
* No new `exhaustion_bucket` field on `runs.jsonl` — YAGNI until a second
  failure requires journal lookups.
* No change to `agent.max_turns` — SYM-22 owns the preemptive-completion
  angle, depends on this diagnosis confirming turn cap is real.
* `read_timeout_ms` mismatch (60000 live vs 120000 in memory) flagged here
  for follow-up; not a María-class issue.
