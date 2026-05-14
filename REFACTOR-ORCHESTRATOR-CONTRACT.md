# Orchestrator Split — Behavior Contract

Refactor of `SymphonyElixir.Orchestrator` from a 1964-LOC god module into
`Orchestrator` (GenServer lifecycle + handle_info) plus sibling modules in
`elixir/lib/symphony_elixir/orchestrator/`.

## Baseline (CP0)

- Branch: `refactor/orchestrator-split`, forked from `main`.
- `mix test`: 320 tests, 0 failures.
- `mix dialyzer`: 0 errors.

## What WILL change

- Public API surface of `SymphonyElixir.Orchestrator`:
  - 4 of 9 `*_for_test/N` shims removed in CP4. Replacements:
    - `parse_github_pr_url_for_test/1`     -> `Orchestrator.PrUrl.parse/1`
    - `sort_issues_for_dispatch_for_test/1` -> `Orchestrator.Dispatch.sort/1`
    - `extract_token_delta_for_test/2`     -> `Orchestrator.TokenMetrics.extract_token_delta/2`
    - `maybe_transition_merged_pr_for_test/3` -> `Orchestrator.PrMerge.maybe_transition/4`
  - 5 shims kept (subsystems still bound to GenServer-private state, not
    extracted in this refactor):
    - `reconcile_issue_states_for_test/2`
    - `should_dispatch_issue_for_test/2`
    - `revalidate_issue_for_dispatch_for_test/2`
    - `apply_state_transition_for_test/2`
    - `select_worker_host_for_test/2`
  - `%Orchestrator.State{}` struct moves to `Orchestrator.State` module (sibling).
- File layout: `orchestrator.ex` drops from 1964 LOC to 1572 LOC (-20%).
  Full split into `~400 LOC` rejected as YAGNI: reconcile + dispatch + workpad
  sync still couple to GenServer state and side-effecting helpers; extracting
  them honestly is a separate refactor, not lipstick.
- Module names emitted in Logger metadata stay; the `Logger.metadata` keys are
  unchanged.

## What MUST NOT change

These invariants are the externally observable contract. Tests + production
e2e validate them.

1. **GenServer message contract.** The `handle_info/2` clauses
   (`:tick`, `{:tick, token}`, `:run_poll_cycle`, `{:worker_runtime_info, ...}`,
   `{:workpad_comment_created, ...}`, `{:workpad_create_failed, ...}`,
   `{:workpad_update_failed, ...}`, `{:retry_issue, ...}`, `{:agent_worker_update, ...}`)
   stay on `SymphonyElixir.Orchestrator` with identical pattern matches and
   identical return tuples.
2. **State struct shape.** `%State{}` fields, default values, and types unchanged.
   Only the defining module moves.
3. **Linear API call sequence per tick.** Same number, same order, same
   filters. Verified by `mix test` (`linear/normalizer_test.exs`,
   `linear/client_filter_test.exs`) + `Orchestrator.Reconcile` tests.
4. **Polling interval.** Driven by `Process.send_after(self(), :tick, interval_ms)`.
   Unchanged.
5. **Dispatch order.** `sort_issues_for_dispatch/1` algorithm preserved
   byte-for-byte. Test in `workspace_and_config_test.exs:912` asserts
   priority ordering.
6. **Workpad idempotency.** `sync_workpad_pr_attached` posts the final-sync
   comment at most once per issue-id. The `running_entry.final_sync_posted?`
   flag stays.
7. **State transitions.** `on_pickup_state` → `on_complete_state` →
   `on_pr_merge_state`. Test in `orchestrator_state_transition_test.exs`
   covers all four matrix cells (configured/absent).
8. **Retry semantics.** `:retry_issue` deduplication via `retry_token` is
   preserved. Test in `orchestrator_token_delta_test.exs`.
9. **Token Delta Guard.** Emergency-halt threshold (150k tokens since last
   PASS) preserved. Same Logger.error wording.
10. **Gate C invocation timing.** Runs on `event: :turn_completed` only.
    Test in `gate_c_test.exs`.
11. **PR merged reconcile.** `pr_merged?/1` shells out to `gh pr view`
    with identical args. The `Task.start(fn -> apply_state_transition/2 end)`
    wrapping stays — the side effect must remain async.
12. **Dialyzer green.** No new warnings introduced.

## Per-checkpoint gates

| CP | Status | Validation |
|----|--------|------------|
| CP0 | DONE   | Baseline tagged. 320t/0f, dialyzer 0. |
| CP1 | DONE   | PrUrl + Dispatch extracted. 320t/0f, dialyzer 0. orchestrator.ex 1964 -> 1957. |
| CP2 | DONE   | State + PrMerge extracted (PrMerge takes `transition_fn` callback to avoid back-ref). 320t/0f, dialyzer 0. orchestrator.ex 1957 -> 1898. |
| CP3 | DONE   | TokenMetrics extracted (310 LOC, 2 public APIs, 16 private helpers). 320t/0f, dialyzer 0. orchestrator.ex 1898 -> 1593. |
| CP4 | DONE   | 4 `*_for_test` shims dropped. Tests rewritten to call sibling APIs directly. 320t/0f, dialyzer 0. orchestrator.ex 1593 -> 1572. |
| CP5 | PARTIAL | Local Application boot smoke test green: orchestrator GenServer up, `%State{}` resolved to extracted module, 14 fields preserved. CI on PR #55 green (make-all + validate-pr-description). **Live e2e vs fresh visual SODEV ticket pending merge-to-main + VPS deploy — both require explicit user authorization (CLAUDE.md prod-safety + main-protection rules).** |

## Coverage policy

Pre-refactor: `SymphonyElixir.Orchestrator` and `Orchestrator.{CodexTelemetry,IssueFilter,State}`
were in `ignore_modules` because their testability profile mixes shell-outs (gh CLI),
payload-shape variants, and defensive sentinel branches with no real-world input.

Post-refactor: same policy extended to `Orchestrator.{Dispatch,PrMerge,TokenMetrics}` —
those modules inherited the same profile when extracted. `Orchestrator.PrUrl` stays
out of the ignore list and reaches 100% via `orchestrator_pr_label_test.exs`.

No coverage debt is hidden — the per-module mix matches what existed pre-refactor.

## Rollback

Each checkpoint is one or more commits and one `git tag refactor-cp-N`.
`git reset --hard refactor-cp-N` returns to a known-good state. Tags pushed
to origin after each green gate:

- `refactor-cp-0` (a3704f0..5b17c44)
- `refactor-cp-1` (5b17c44..99af157)
- `refactor-cp-2` (99af157..a9e9879)
- `refactor-cp-3` (a9e9879..7570735)
- `refactor-cp-4` (7570735..09a40f1)

PR #55 head: 381d0a0 (cumulative refactor + credo-alias fix + coverage-ignore fix).
