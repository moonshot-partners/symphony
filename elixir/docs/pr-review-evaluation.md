# PR-review tooling — claude-pr-review vs. GStack `/review`

SYM-14 deliverable. Juan suggested swapping the current claude-pr-review
plugin for GStack `/review` (2026-05-20 School's Out working session). This
doc compares the two against Symphony's autonomous-loop requirements and
records the decision.

## Current state — claude-pr-review

* Trigger: `pull_request` event in
  `schoolsoutapp/{schools-out,fe-next-app}/.github/workflows/claude-pr-review.yml`,
  gated on the `symphony` PR label.
* Runtime: `anthropics/claude-code-action@v1` with the
  `pr-review-toolkit@claude-code-plugins` marketplace plugin.
* Five sub-agents fan out via the Task tool in parallel: `code-reviewer`,
  `silent-failure-hunter`, `pr-test-analyzer`, `comment-analyzer`,
  `type-design-analyzer`.
* Output: a single aggregated PR comment whose body starts with the literal
  header `# claude-pr-review: <approve|comment|request_changes>`. Symphony's
  `GitHubPr.critical_review_pending?/1` parses that header verbatim, then
  `PrReengagement` fires K=1 auto re-engagement on `request_changes`.
* Per-PR cost: one CI run, ~3-5 minutes wall-clock, charged to the
  `CLAUDE_CODE_OAUTH_TOKEN`.
* Same workflow also mirrors the comment body to the Linear workpad so the
  CTO can see findings without leaving Linear.

## GStack `/review`

Garry Tan's open-source Claude Code skill pack (`garrytan/gstack`),
released March 2026, MIT-licensed. The `/review` skill is positioned as a
"paranoid staff engineer" pre-PR audit that flags N+1 queries, race
conditions, trust-boundary violations, broken invariants, and missing test
coverage.

* Trigger: **invoked locally as a slash command inside Claude Code.** Not a
  GitHub Actions workflow. The `garrytan/gstack` repo's own workflows are
  CI for the skill pack itself (lint, docs freshness, evals) — none of them
  is a portable PR-review action you could install on `fe-next-app` or
  `schools-out`.
* Runtime: a single sub-agent with the `/review` system prompt running
  inside the developer's Claude Code session.
* Output: terminal output for auto-fixes plus escalations into a "Review
  Readiness Dashboard"; no standardized GitHub-PR comment format
  documented.
* Cost: tied to the developer's Claude Code subscription, not a CI token.

## Side-by-side fit against Symphony requirements

| Requirement | claude-pr-review | GStack `/review` |
|---|---|---|
| Fires automatically on every agent PR | yes (GHA event) | no (manual slash) |
| Runs in CI with a long-lived token | yes | no — Claude Code session |
| Posts a parseable verdict header to the PR | yes, contract-stable | no documented format |
| Multi-agent specialization | 5 agents in parallel | 1 generalist agent |
| Mirrors to Linear workpad | yes (next step in same workflow) | no integration |
| Composes with K=1 re-engagement (`PrReengagement`) | yes — header is the contract | would need a new parser |
| One-round-review policy | already enforced | not modeled |

## Decision — keep claude-pr-review

Switching is **not viable** today. GStack `/review` is a developer-loop tool;
Symphony's review gate is an autonomous-CI integration. Replacing the
former with the latter would require building a brand-new GHA wrapper that
shells out to `claude` with the GStack skill installed, parses freeform
terminal output into the `# claude-pr-review: <verdict>` shape, and
re-implements the Linear workpad mirror — none of that is a saving over the
working code we have.

What stays viable: GStack `/review` as a **complementary local tool** when a
human reviewer triages a Symphony PR before merging. That's a per-developer
preference, not a Symphony infra change, and does not justify any
orchestrator-side work.

## Reopen criteria

Reopen this evaluation if any of these change:

* GStack ships a first-party GitHub Action that emits a parseable PR
  verdict comment.
* claude-pr-review false-positive rate becomes painful enough to outweigh
  the integration cost (track via SYM-17 K=1 bake — count of
  `request_changes` verdicts that the agent's re-engagement turn flipped
  back to clean).
* The 5-agent fan-out cost becomes a real budget constraint (track via
  weekly KPI `mix runs.weekly`).

Until one of those fires, claude-pr-review stays the review gate.
