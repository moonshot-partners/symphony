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
  - The nine `*_for_test/N` shims are removed in CP4.
  - Their bodies move into public functions on sibling modules:
    - `Orchestrator.PrUrl.parse/1`
    - `Orchestrator.PrMerge.merged?/1`, `Orchestrator.PrMerge.maybe_transition/3`
    - `Orchestrator.TokenDelta.extract/2`
    - `Orchestrator.Dispatch.sort/1`, `Orchestrator.Dispatch.should_dispatch?/4`,
      `Orchestrator.Dispatch.revalidate/3`, `Orchestrator.Dispatch.select_worker_host/2`
    - `Orchestrator.Reconcile.run/3`, `Orchestrator.Reconcile.apply_state_transition/2`
    - `Orchestrator.WorkpadSync.pr_attached/2`
  - `%Orchestrator.State{}` struct moves to `Orchestrator.State` module (sibling).
- File layout: `orchestrator.ex` drops from 1964 LOC to ~400 LOC.
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

| CP | Validation |
|----|------------|
| CP1 | `mix test` + `mix dialyzer` green. New sibling modules covered by relocated tests. |
| CP2 | Same as CP1 + assert `%State{}` struct identity preserved. |
| CP3 | Same as CP1. Workpad sync test covers post-once invariant. |
| CP4 | All `*_for_test` callers rewritten to use sibling public API. Suite still 320 tests, all green. |
| CP5 | Real visual SODEV ticket dispatched against deployed refactor branch on VPS. Full workpad timeline observed (pickup → understanding.md → PR opened → QA evidence → state transitioned). |

## Rollback

Each checkpoint is one or more commits and one `git tag refactor-cp-N`.
`git reset --hard refactor-cp-N` returns to a known-good state. Push happens
after each checkpoint goes green, so origin has the same tags.
