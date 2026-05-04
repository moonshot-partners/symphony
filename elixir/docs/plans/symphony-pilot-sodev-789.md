# Symphony Pilot — SODEV-789 Baseline + Agent Comparison

**Status:** DONE — agent PR #754 ready for human review/merge
**Date:** 2026-04-30
**Author:** Vini + Claude (autonomous)
**Verdict:** see `/tmp/sodev-789-baseline/COMPARISON.md`. Agent ≥ baseline on every correctness axis; strictly better on PR description, commit messages, and test coverage. Single concern: bash reads outside workspace under `bypassPermissions` (filed as follow-up).

## Goal

Run Symphony orchestrator end-to-end on a real production-grade ticket (SODEV-789, robots.txt Disallow rules for `my.schoolsoutapp.com`) and **evaluate output quality against a human-built baseline**.

Pilot evidence target: a PR that the team can review and (ideally) merge to `dev`/`main` in `schoolsoutapp/schools-out`. Stretch goal: prove agent finds root cause (sitemap URL also wrong) not just the symptom Matt flagged (missing Disallow rules).

## Why baseline-first

Plain "Symphony shipped a PR" is a low bar. With a privately-built baseline:
- Oracle/ground truth to grade agent output
- Catches wrong-repo, wrong-file, wrong-cause failures
- Evaluates dimensions beyond "did it run": root cause vs symptom, edge cases, PR description, commit message
- Risk hedge: if agent fails, baseline is ready to ship

## Safety constraints

User flagged: **do not break production or colleagues' WIP**.

Confirmed state:
- `~/Developer/schoolsout/schools-out` has WIP (UU `db/structure.sql` conflict + 1 stash on `main`). **DO NOT touch.**
- `~/code/schoolsout-workspaces/SODEV-817|818` are Symphony agent workspaces. **DO NOT touch.**
- Baseline work isolated in `/tmp/sodev-789-baseline/` (fresh clone, local only).
- **NO PUSH** to `schoolsoutapp/schools-out` from the baseline branch. Symphony agent's PR is the only push to remote.
- **DO NOT modify** Matt Bowers' SODEV-789 ticket in Linear. Symphony runs on a sandbox-project copy.
- No production deploys. No CI triggers from baseline branch.

## Phase 0 — Investigation (no-code, written notes)

**Output:** `/tmp/sodev-789-baseline/INVESTIGATION.md` with confirmed facts.

- [ ] Clone schools-out fresh to `/tmp/sodev-789-baseline/schools-out` (depth 1, main branch)
- [ ] Map how `my.schoolsoutapp.com/robots.txt` is served:
  - Is `public/robots.txt` shared across all subdomains, or is there subdomain-aware routing?
  - Search `config/routes.rb`, controllers for `robots`, middleware
  - Check Rails app for subdomain constraints
- [ ] Check open PRs in `schoolsoutapp/schools-out` touching `public/robots.txt`, `config/routes.rb`, or any robots-related controller — avoid stepping on colleague WIP
- [ ] Check live state of `my.schoolsoutapp.com/robots.txt` vs `www.schoolsoutapp.com/robots.txt` (different content? same?)
- [ ] Confirm Matt's specific URL patterns from SODEV-789 (`/{city}/{category}/evnt_{id}/{slug}`, `/v1/camps/`, `/v2/camps/`, `/activities`)
- [ ] Identify sitemap URL bug Matt flagged: current points to `https://www.schoolsout.com/sitemap.xml` (wrong domain — should be `schoolsoutapp.com`)
- [ ] Check if `data-ingestion-admin` repo (also has `public/robots.txt`) is relevant — likely Maestro-only, separate domain

**Acceptance for Phase 0:** Written notes answer: which file(s) to edit, are there subdomain-specific configs, is sitemap URL fixable in same diff, are colleagues working in this area, what is the safe diff scope.

## Phase 1 — Manual baseline (private branch, no push)

**Output:** Branch `vini/sodev-789-baseline-manual` in `/tmp/sodev-789-baseline/schools-out` + `EXPECTED.md` documenting the solution.

- [ ] Branch from `main` in isolated clone
- [ ] Edit identified file(s) per Phase 0 findings
- [ ] Add Disallow rules covering Matt's documented patterns
- [ ] Fix sitemap URL (root cause of secondary issue)
- [ ] If subdomain routing exists, ensure `my.schoolsoutapp.com/robots.txt` differs from `www.schoolsoutapp.com/robots.txt` appropriately
- [ ] Commit locally with message referencing SODEV-789
- [ ] Write `/tmp/sodev-789-baseline/EXPECTED.md`:
  - Files touched
  - Reasoning (why these specific Disallow patterns)
  - Edge cases considered (sitemap URL, 301 redirects mentioned by Matt as separate)
  - What I'd put in PR description

**Acceptance for Phase 1:** Local commit on private branch + EXPECTED.md complete. **Zero pushes.**

## Phase 2 — Symphony parallel run

**Output:** Agent-shipped PR on `schoolsoutapp/schools-out`. Run logs.

- [ ] Create sandbox-project copy of SODEV-789 in Linear:
  - Title: `[Symphony pilot] GSC: my.schoolsoutapp.com robots.txt Disallow + sitemap fix`
  - Description: full SODEV-789 body + footer linking SODEV-789 + note "Symphony pilot run"
  - Project: Symphony E2E Sandbox
  - Assignee: vinicius.freitas@moonshot.partners
  - State: Scheduled
  - Priority: Low
- [ ] Verify Symphony config picks it up (project_slug match, active_states match)
- [ ] Boot Symphony orchestrator: `mix run --no-halt` from `~/Developer/symphony/elixir`
- [ ] Watch agent: turn count, files touched, PR URL
- [ ] Capture artifacts: PR number, branch name, time-to-PR, turns used

**Acceptance for Phase 2:** PR opened by Symphony agent on `schoolsoutapp/schools-out`. Run terminates cleanly (no respawn loop).

## Phase 3 — Comparison + verdict

**Output:** Comparison table + decision (merge agent PR / merge baseline / hybrid / abort).

- [ ] Diff agent PR vs baseline branch
- [ ] Score axes:
  - **File correctness:** did agent edit the right file(s)?
  - **Disallow patterns:** does agent cover Matt's full URL pattern set?
  - **Root cause depth:** did agent fix sitemap URL too, or only Disallow rules?
  - **Edge cases:** did agent address subdomain routing, 301 redirects, GSC Sitemap field?
  - **PR description quality:** clear context, links SODEV-789, explains decisions
  - **Commit message:** atomic, descriptive
  - **Side effects:** any unrelated diff (formatting, deps, config drift)?
- [ ] Decide:
  - If agent PR ≥ baseline → request Vini review + merge
  - If agent PR < baseline → use baseline (post-mortem on agent gaps)
  - Hybrid → cherry-pick agent's good parts onto baseline diff
- [ ] Update memory with run findings (turn count, failure modes, surprise wins/losses)

**Acceptance for Phase 3:** Written verdict + a single PR ready to merge to `dev` (or back to `main` per repo convention).

## Out of scope

- 301 redirects for high-traffic legacy URLs (Matt scoped as separate evaluation)
- Other GSC tickets (788, 790, 792, 793)
- GitHub App identity (Phase D blocker, separate)
- Multi-ticket parallel dispatch
- Agent retry on failure beyond default Symphony behavior

## Rollback

- Phase 0–1: nothing pushed, just delete `/tmp/sodev-789-baseline/`
- Phase 2: if agent ships broken PR, close PR without merge, no merge to main
- Phase 3: if both baseline and agent PR have issues, do not merge anything; postmortem instead
