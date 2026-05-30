# Move e2e/QA Validation from the Agent Turn to CI

**Date:** 2026-05-30
**Status:** Approved (decision made with Vini; research + reviewer-feedback grounded; awaiting phased implementation)
**Driver:** The agent self-runs Playwright e2e/QA inside its turn — expensive ($2.50–3.50, 8–12min per frontend ticket per Langfuse), environment-fragile (PR #642 QA self-review returned `BLOCKED`: `NEXT_PUBLIC_GOOGLE_CLIENT_ID` not set in the agent test env), and the cause of the no-PR loop (e2e eats the turn before push). Every frontend PR also carries a `BLOCKED QA self-review` table that is not real evidence — GitHub noise.
**Origin:** Session 2026-05-30 (simplify Symphony toward upstream + reduce GitHub noise + unblock the agent).

## Context

Symphony is a fork of `openai/symphony` (lean Codex orchestrator: poll → dispatch → reconcile, CI validates). The fork added an agent-side QA self-review stack (`WORKFLOW.schools-out.md` rule 5-PT Playwright, `qa_evidence.ex`, the qa-artifact gate in `workpad_pr_sync.ex`). That stack is the divergence and the friction source.

Measured (Langfuse, 2026-05-30):
- SODEV-430 turn `6154f0f6`: 734s / $3.28 — full implement + 2× `CI=1 npm run e2e` (Playwright) + push.
- SODEV-430 turn `a48146f6`: 245s / $1.24 — push + PR only (no e2e).
- The delta is entirely the e2e self-review.

`fe-next-app` CI today (verified on PR #642): Lint + unit Test + qa-evidence gate + scope-discipline + claude-pr-review. **No Playwright e2e job.** So the agent's self-run e2e is the only e2e anywhere, and it runs in a fragile local env.

Reviewer feedback (María Rodríguez, Slack DM): her concern was GitHub noise — one task split into multiple step-PRs, and PRs that were hard to map back to a Linear task. Both are **already resolved** in Symphony (verified on PR #642: one branch/PR per ticket, no step-splitting; PR body carries the Linear link + AC-trace). The remaining GitHub noise she would still see is the `BLOCKED QA self-review` block this spec removes. Her input is honored by reducing noise, not by restricting which tickets the agent works on.

Web-research consensus (2025/2026): agents run fast local tests (unit + lint) to iterate; e2e/critical validation runs in CI with Playwright artifacts (report, screenshots, video, trace) as evidence; humans on-the-loop at PR review. That is also the upstream lean model.

## Goal

Relocate e2e validation from the agent turn to `fe-next-app` CI without losing it. After this:
- Agent turn: implement → unit test → lint → push → PR. No browser/e2e self-review. ~5× cheaper/faster, no env fragility, no no-PR loop.
- CI runs Playwright e2e on every PR with the proper env + uploads the report/screenshots/video/trace as the evidence.
- The Symphony qa-evidence gate verifies CI ran e2e (artifact / required check) instead of agent-pasted screenshots.

## Non-Goals

- Not removing the GateD substance check, claude-pr-review, unit-test, or lint gates — those stay.
- **Not limiting which tickets the agent can pick** (no cycle/scope restriction — explicitly out, the agent must stay unblocked).
- Not the structural collapse of orchestrator infra-helper modules (separate decision: rejected as net-negative).
- Not changing one-PR-per-task, the Linear link in PR descriptions, or SYM-16 re-engagement — all verified already working.

## Phases (ordered for regression safety — never lose e2e validation in the gap)

### Phase 0 — `fe-next-app` CI gains the e2e job (THEIR repo, FIRST)
Add a Playwright job to `fe-next-app` `.github/workflows/ci.yml` that runs on PRs with the proper env (`NEXT_PUBLIC_GOOGLE_CLIENT_ID` etc.), runs a smoke subset on PR (full suite nightly/pre-merge to avoid CI slowness/flakiness), and uploads the Playwright HTML report + screenshots/video/trace as a PR artifact. This MUST land and be green before any Symphony-side removal. Cross-repo + CI infra → coordinate with the schoolsout team (the scope-discipline gate blocks `.github/workflows` edits; needs their review). Not auto-executed by Symphony.

### Phase 1 — Symphony: drop the agent QA self-review from the default flow
Once Phase 0 CI e2e is live and green: remove the `WORKFLOW.schools-out.md` rule 5-PT (mandatory agent Playwright run + QA self-review table) and the agent-side qa-evidence requirement. The agent stops self-running e2e and stops pasting a `## QA self-review` / `BLOCKED` block. `qa_evidence.ex` (the optional uploader) can stay dormant or be removed in a later cleanup; the immediate change is the WORKFLOW rule + the gate (Phase 2).

### Phase 2 — Symphony: qa-evidence gate reads CI, not pasted screenshots
Change the qa-artifact gate in `workpad_pr_sync.ex` from "PR body has `## QA self-review` with real artifacts staged" to "the PR's e2e CI check passed" — or simply make the `fe-next-app` e2e job a required PR check and drop the Symphony-side qa-artifact gate entirely (preferred: let GitHub required-checks enforce it, Symphony just reads check status via the existing `ChecksClassifier`).

### Phase 3 — Validate e2e + Langfuse
After Phase 1/2 land: smoke-test a markdown ticket + a frontend ticket, confirm via Langfuse that the agent turn is ~5× cheaper, no QA self-review block, the PR carries CI e2e evidence, and runs.jsonl carries trace_id + cost_usd.

## Risks

- Phase 0 e2e in CI can be slow/flaky → mitigate with a smoke subset on PR, full nightly.
- Removing agent e2e before CI e2e exists would lose validation → enforced by phase ordering (Phase 0 first, hard prerequisite).

## Verification

- Per phase: mix format + credo + full Elixir suite (Symphony phases); CI green (fe-next-app phase); smoke ticket + Langfuse check (Phase 3).
- Regression: e2e validation must exist in CI (Phase 0 green) before Symphony drops it (Phase 1).
