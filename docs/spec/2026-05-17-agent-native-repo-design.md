# Agent-Native Repo Migration — Phase 1

**Date:** 2026-05-17
**Status:** Approved (brainstorming complete, awaiting implementation plan)
**Driver:** Real pressure to de-couple Symphony from `schools-out`-specific content before second client onboards.
**Origin:** Self-DM ticket "Symphony — Migração Agent-Native Repo (Plano para sessão futura)" (2026-05-17 00:22 UTC).

## Context

Symphony today carries 646 lines of `schools-out`-specific configuration inside its own
orchestrator file (`elixir/WORKFLOW.schools-out.md`). The file mixes three concerns:

1. **Infra config** (89-line YAML frontmatter) — tracker, polling, workspace, hooks,
   agent, agent_runtime. Owned by the orchestrator; must be loaded before workspace checkout.
2. **Agent rules** (~557 lines of Markdown body) — operating rules, AC trace contract,
   QA self-review paths (5-PT Playwright + 5-LH legacy), hard stops, workpad template.
   These describe **how to work on this codebase**, not how the orchestrator runs.
3. **Engine contracts mixed into agent rules** — `Symphony moves the ticket to In QA / Review`,
   `/opt/qa/qa_publish.py`, `Symphony's QaEvidence uploader`. These describe engine behavior
   and create instruction-drift risk when the engine changes.

In parallel, the engine has hardcoded `schools-out`-shaped paths:

- `elixir/lib/symphony_elixir/qa_evidence.ex:20` — `@evidence_subpath "fe-next-app/qa-evidence"`
- `elixir/lib/symphony_elixir/gate_c.ex:4` — moduledoc references `WORKFLOW.schools-out.md` by name

Without a refactor, "just moving the markdown" leaves the engine `schools-out`-shaped
and any new client would silently misbehave on `qa-evidence` uploads.

## Goal

Make Symphony multi-tenant ready for the second client without re-touching the engine.
After this migration:

- A new client = new `WORKFLOW.<tenant>.md` (YAML only) + their own `AGENTS.md` in their repo.
- Zero Elixir code changes per new tenant.
- The engine reads tenant-specific paths from `WORKFLOW` config, not from constants.

## Non-Goals (deferred to later phases per the origin ticket)

- **Write-back** (agent updating `AGENTS.md`). Experimental at Anthropic. Not in scope.
- **Phase 2** — Docker image agnostic, removal of `qa_helpers.py`, `qa_vendor.py`,
  `qa_session.py`, `qa_devserver.py`. Prereq: 5-LH path removed from WORKFLOW.
- **`allowed_repos` config field** — defer until `after_create` hook is generalized to
  consume it (Phase 3 territory). Adding the field with no consumer is YAGNI. The
  hook still does literal `git clone https://github.com/schoolsoutapp/schools-out`
  this phase; that line moves to a generic loop when Phase 3 lands.
- **Phase 3** — generic `after_create` hook. Per-tenant bash hook stays until 3+ clients
  feel real pain.
- **Symphony self-loop body shrink** — `WORKFLOW.md` (Symphony's own ticket loop) keeps
  its body; defer to follow-up PR after `schools-out` is validated.
- **`gate_c.ex` business logic** — only the moduledoc reference is in scope this phase.
- **SODEV-NNN comment references** in `github_pr.ex`, `linear/telemetry.ex`,
  `retry_dispatch.ex`. Historical context, not coupling.

## Architecture

```
Orchestrator-side (Symphony repo, this branch):
  elixir/WORKFLOW.schools-out.md
    YAML frontmatter (infra, grows ~3L):
      tracker, polling, workspace, hooks, agent, agent_runtime
      + qa.evidence_subpath: "fe-next-app/qa-evidence"
    Markdown body (shrinks ~557L -> ~25L):
      "Read AGENTS.md + CLAUDE.md in workspace root and every subdir you touch.
       Follow them as primary instructions."
      + Solid ticket prompt template (issue.identifier, issue.title, attempt, etc.)

Client-side (schoolsoutapp/schools-out @ dev):
  AGENTS.md (new file, PR'd via separate session):
    pr_base: dev
    Operating rules (Step 0, AC trace, understanding.md format)
    Quality gates (rubocop, RSpec before/after)
    Hard stops
    Workpad template

Client-side (schoolsoutapp/fe-next-app @ dev):
  AGENTS.md (new file, PR'd via separate session):
    pr_base: dev
    Next.js gates (npm code:fix, code:check, npm test)
    QA rules (5-PT Playwright path with captureEvidence)
    Visual-AC mount check

Engine refactor (Symphony repo, this branch):
  elixir/lib/symphony_elixir/config.ex
    + qa_evidence_subpath/0  (reads from settings, default = current hardcode)
    + allowed_repos/0
  elixir/lib/symphony_elixir/config/schema.ex
    + qa: %{evidence_subpath: String.t()}
    + allowed_repos: [String.t()]
  elixir/lib/symphony_elixir/qa_evidence.ex
    @evidence_subpath constant -> Config.qa_evidence_subpath/0
  elixir/lib/symphony_elixir/gate_c.ex
    moduledoc: drop "WORKFLOW.schools-out.md" string reference
```

## Components & file changes

### Engine (Symphony repo, this branch)

| File | Change | Risk |
|---|---|---|
| `elixir/lib/symphony_elixir/config.ex` | Add `qa_evidence_subpath/0`. Reads from settings; defaults to current hardcoded value. | Low |
| `elixir/lib/symphony_elixir/config/schema.ex` | Extend `Schema.t()` struct with `qa` embedded schema (`evidence_subpath` field). | Low |
| `elixir/lib/symphony_elixir/qa_evidence.ex` | Replace `@evidence_subpath` constant with `Config.qa_evidence_subpath/0` call site. | Medium — runs on every view-layer ticket. |
| `elixir/lib/symphony_elixir/gate_c.ex` | Drop literal `WORKFLOW.schools-out.md` reference from moduledoc. | Trivial (docs only). |
| `elixir/WORKFLOW.schools-out.md` | Body shrinks ~557L -> ~25L. YAML grows ~10L (new fields). | High — agent prompt change. |
| `elixir/test/symphony_elixir/qa_evidence_test.exs` | Test config-driven path resolution. | Required (TDD). |
| `elixir/test/symphony_elixir/config_test.exs` | Test new YAML fields parse + defaults. | Required (TDD). |
| `elixir/test/symphony_elixir/workflow_body_smoke_test.exs` (new) | Assert body length cap + presence of `AGENTS.md` reference. Catches accidental drift. | Required. |

### Client repos (separate PRs, separate sessions, separate branches)

| Repo | File | Branch | PR base | Authoring |
|---|---|---|---|---|
| `schoolsoutapp/schools-out` | `AGENTS.md` (new) | `chore/agents-md-bootstrap` | `dev` | Claude authors content by extracting backend-relevant sections from current `WORKFLOW.schools-out.md` body. Opens PR via local clone + `gh pr create`. User reviews + merges. |
| `schoolsoutapp/fe-next-app` | `AGENTS.md` (new) | `chore/agents-md-bootstrap` | `dev` | Same flow — Claude extracts Next.js + QA Playwright sections. User reviews + merges. |

## Data flow

**Today (Step 0 — agent boot):**

```
Symphony dispatch
  -> PromptBuilder.build_prompt(issue)
  -> renders WORKFLOW.schools-out.md body (557L) as system prompt
  -> agent reads system prompt (contains all rules)
  -> agent runs `cat AGENTS.md 2>/dev/null` (returns empty, tolerated)
  -> starts work
```

**After migration:**

```
Symphony dispatch
  -> PromptBuilder.build_prompt(issue)
  -> renders WORKFLOW.schools-out.md body (~25L) as system prompt
  -> system prompt: "Read AGENTS.md + CLAUDE.md in workspace root + every subdir you touch."
  -> agent runs `cat AGENTS.md` (returns full rules from client repo)
  -> agent runs `cat fe-next-app/AGENTS.md` if ticket touches frontend
  -> starts work
```

**QA evidence path (config-driven):**

```
Pre-migration:                              Post-migration:
qa_evidence.ex:20                           qa_evidence.ex
  @evidence_subpath "fe-next-app/qa-evid"     subpath = Config.qa_evidence_subpath()

                                            config.ex
                                              qa_evidence_subpath/0 reads from
                                              settings.qa.evidence_subpath
                                              default: "fe-next-app/qa-evidence"
```

Default = current hardcoded value -> zero behavior change at deploy.

## Strangler-fig deployment order (zero downtime)

| Phase | Action | Validation gate |
|---|---|---|
| **A** | Engine refactor (config-driven, defaults match current hardcode). Merge + deploy via `deploy.sh`. | Dispatch 1 smoke ticket. User confirms workpad behavior matches pre-migration. |
| **B** | Create `AGENTS.md` in `schools-out` and `fe-next-app` (full current rules verbatim). Open 2 PRs against `dev`. User reviews content before merging. Merge both. | `cat AGENTS.md` returns expected content in a fresh workspace clone. |
| **C** | Shrink `WORKFLOW.schools-out.md` body to ~25L pointer. Merge + deploy via `deploy.sh`. | Dispatch smoke + view-layer ticket. User confirms zero regression. |
| **D** | Burn-in: 10+ real SODEV tickets over days. User observes Linear workpads. | Halt criteria: any regression vs pre-migration behavior. |

**Hard rollback gate:** never revert B while C is live. Order: revert C first, then B.

**Pre-migration safety net:** snapshot current `WORKFLOW.schools-out.md` to
`WORKFLOW.schools-out.md.pre-agent-native.bak` (gitignored) for manual diff during validation.

## Error handling

| Failure | Detection | Mitigation |
|---|---|---|
| `AGENTS.md` missing in client repo (PR not merged) | `after_create` hook runs `test -f AGENTS.md` post-clone; fails loud if absent (after Phase C deploy). | Hook fails -> Symphony marks workspace creation failed -> ticket stays in `Scheduled`. Operator sees clear error, merges the PR, ticket re-dispatches. |
| YAML field `qa.evidence_subpath` missing | `Config.qa_evidence_subpath/0` falls back to default `"fe-next-app/qa-evidence"`. | Default = current hardcoded value. Zero behavior change. Logged at boot. |
| `AGENTS.md` content corrupted / partial | Burn-in (Phase D) catches downstream regressions. Per-AGENTS.md CI check: assert key sections present (Step 0, AC trace, workpad). | Add `.github/workflows/agents-md-lint.yml` in each client repo (out of scope this PR, follow-up). |
| Engine refactor breaks `qa_evidence` upload | `qa_evidence_test.exs` (TDD) + 1 view-layer ticket (Phase A validation). | TDD catches unit. E2E catches integration. |
| Migration deployed before client repos have `AGENTS.md` | Strict deploy order A -> B -> C. Phase C is the only one that needs B intact. | Phase C deploy script asserts: `gh api repos/schoolsoutapp/schools-out/contents/AGENTS.md?ref=dev` returns 200. Block deploy if 404. |

## Testing strategy

**Unit (TDD, RED -> GREEN -> REFACTOR):**

1. `workspace_and_config_test.exs` (extend existing):
   - parses `qa.evidence_subpath` from YAML as string
   - defaults to `"fe-next-app/qa-evidence"` when `qa` block omitted (no behavior change)
2. `qa_evidence_test.exs`:
   - resolves subpath from `Config.qa_evidence_subpath/0`
   - existing tests stay green (no public API change)
3. `workflow_body_smoke_test.exs` (new):
   - asserts WORKFLOW body contains literal `AGENTS.md` reference
   - asserts body length cap (e.g. <= 40 lines) — catches drift back to fat body

**Integration (Symphony self-test):**

4. `core_test.exs:123` ("current WORKFLOW.md file is valid and complete") stays green with shrunken body.

**E2E (manual, real Symphony dispatch — user validates each):**

5. **Phase A smoke ticket (~10min):**
   - Create SODEV ticket: small backend config change (no UI).
   - Dispatch via Symphony.
   - Assert: agent boots, writes `understanding.md`, opens PR with correct base (`dev`).
   - No `AGENTS.md` involved yet — pure engine refactor validation.
6. **Phase C smoke ticket (~10min):**
   - After AGENTS.md merged in client repos. Dispatch same kind of ticket.
   - Assert: agent runs `cat AGENTS.md`, follows rules from there, opens PR.
7. **Phase C view-layer ticket (~30min):**
   - Small UI change in `fe-next-app`.
   - Assert: agent reads `fe-next-app/AGENTS.md`, executes rule 5-PT (Playwright),
     uploads qa-evidence, PR opens with `## QA self-review` section.
8. **Phase D burn-in (~days, async):**
   - 10+ real SODEV tickets. Mix simples / view-layer / bugfix / refactor.
   - Halt criteria: any regression vs pre-migration behavior.

## Manual validation gates (per phase)

- **After Phase A** merged + deployed: dispatch 1 smoke ticket; user confirms workpad shows expected behavior.
- **After Phase B** PRs opened: user reviews `AGENTS.md` content in both client PRs before merging.
- **After Phase B** merged: `curl raw.githubusercontent.com` returns expected `AGENTS.md` content in both repos.
- **After Phase C** merged + deployed: dispatch smoke + view-layer; user confirms zero regression.
- **Phase D** burn-in: user observes Linear workpads over days, flags any unexpected behavior.

## Out of scope (explicit YAGNI)

- New CI workflow to lint `AGENTS.md` content in client repos.
- `WORKFLOW.md` (Symphony self-loop) body shrink.
- `gate_c.ex` business logic refactor.
- SODEV-NNN historical comment cleanup.
- Phase 2 (Docker image agnostic) and Phase 3 (generic hook).

## Open questions

None. All design decisions resolved during brainstorming:

- Engine de-coupling scope: refactor now (config-driven).
- "Allowed repos" location: YAML (orchestrator-side, per SOTA AGENTS.md spec).
- "PR base branch" location: AGENTS.md (per-repo convention, per SOTA).
- Validation depth: 10+ ticket burn-in (Phase D).

## References

- AGENTS.md spec (Linux Foundation / Agentic AI Foundation): <https://agents.md/>
- OpenAI Codex AGENTS.md guide: <https://developers.openai.com/codex/guides/agents-md>
- AGENTS.md Patterns — instruction-drift failure modes: <https://blakecrosley.com/blog/agents-md-patterns>
- Origin ticket (Vinicius self-DM, Slack): TS `1778988132.876579`
