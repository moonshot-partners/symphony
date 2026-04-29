---
tracker:
  kind: linear
  # Linear project: "Symphony E2E Sandbox" (id 3792a5e9-efa6-4677-83f1-c47cbeacc249)
  # Description on Linear: "Isolated project for testing Symphony agent runtime
  # end-to-end. Only Vinicius issues here. Safe to wipe."
  # Add tiny PR-generating test tickets here. Do NOT widen the slug to a real
  # delivery project until the agent has landed at least one human-reviewed PR.
  project_slug: "symphony-e2e-sandbox-c2bd55c135ce"
  assignee: vinicius.freitas@moonshot.partners
  active_states:
    - Scheduled
    - In Development
  terminal_states:
    - Released / Live
    - Closed
    - Canceled
    - Duplicate
polling:
  interval_ms: 5000
workspace:
  root: ~/code/schoolsout-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/schoolsoutapp/schools-out .
    if [ -f Gemfile ]; then
      bundle install --quiet || true
    fi
  before_remove: |
    : # no-op (do not modify branches on workspace teardown)
agent:
  max_concurrent_agents: 1
  max_turns: 25
agent_runtime:
  command: $SYMPHONY_AGENT_SHIM_PYTHON -m symphony_agent_shim
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
server:
  host: 127.0.0.1
  port: 4000
---

# Schools Out — Symphony Workflow

Drives a Linear-tracked ticket on `schoolsoutapp/schools-out` end-to-end:
read ticket -> implement -> test -> open PR -> hand off to human review.

## Pre-flight (do once before the first run)

1. Linear project `Symphony E2E Sandbox`
   (slug `symphony-e2e-sandbox-c2bd55c135ce`) already exists and is wired
   above. It is intentionally isolated — *"Only Vinicius issues here. Safe
   to wipe."* Do not repurpose it for real delivery work.
2. Add a **small** test ticket inside that project, assigned to you. The
   first such ticket is `SODEV-810` (`Symphony E2E V1: add SYMPHONY.md
   banner via PR`); add new ones in the same shape — tiny verifiable diff,
   acceptance criteria expressed as `git diff --stat`, no app logic.
3. Confirm `ANTHROPIC_OAUTH_TOKEN` (preferred) or `ANTHROPIC_API_KEY` is set
   in the environment that runs Symphony, and that `LINEAR_API_KEY` is set.
4. Confirm `gh auth status` shows write access to `schoolsoutapp/schools-out`.

Do **not** point this workflow at large multi-day tickets (SODEV-796 etc.)
on the first run, and do **not** widen `tracker.project_slug` to a real
delivery project until a Sandbox ticket has been landed end-to-end.

## Ticket prompt

You are working on Linear ticket `{{ issue.identifier }}`.

{% if attempt %}
Continuation context:

- Retry attempt #{{ attempt }} — issue still active.
- Resume from current workspace state. Do not redo completed work.
  {% endif %}

Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
State: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Operating rules

1. **Unattended.** Never ask a human to do follow-up steps. If blocked by
   missing required auth/secrets/permissions, record the blocker in the
   workpad and stop. Anything else, keep going.
2. **One workpad per ticket.** Find or create a single Linear comment
   starting with `## Symphony Workpad`. Write all progress there. Do not
   spam additional comments.
3. **Scope discipline.** Implement only what the ticket's Acceptance
   Criteria require. Out-of-scope improvements -> file a follow-up Linear
   issue in `Backlog`, link as `related`, do not expand current scope.

## Repo conventions

- Always branch off latest `origin/main`. Pull/rebase before any push.
- Branch naming: `agents/sodev-{{ issue.number }}-<short-slug>` (matches
  existing convention: see `agents/sodev-594-clean`). Lowercase, dashes.
- Commits: small, atomic, descriptive. One logical change per commit.
- PRs: target `main`. Title `[SODEV-{{ issue.number }}] <one-line>`.
  Apply label `symphony`. Request review from `vinicius.freitas`.
  **Never** call `gh pr merge` — humans merge.
- Never force-push to a branch with PR comments unless you re-add the
  reviewers and re-explain the rebase in a comment.

## Quality gates (mandatory before push)

Run all of these from the cloned repo root and confirm green before
pushing or moving the ticket out of `In Development`:

1. **Lint / static checks.** Whatever the project uses
   (`bundle exec rubocop`, `yarn lint`, etc — detect from `Gemfile` /
   `package.json` and run the matching command).
2. **Tests.** Targeted suite first (just the files you changed), then a
   wider suite if changes are broad.
3. **Build / boot.** If the change touches boot path, run
   `bin/rails runner "puts :ok"` (or equivalent) to catch load errors.

If any gate fails, fix and rerun. Do not push red.

## Status flow

- `Scheduled` -> on pickup, move to `In Development`.
- `In Development` -> implement + test + push + open PR.
- After PR is open, green CI, and acceptance criteria met:
  move to `In QA / Review`. Stop and wait for humans.
- `Released / Live` / `Closed` / `Canceled` / `Duplicate` -> terminal,
  do nothing.

If the ticket is in a state not listed (`On Hold / Blocked`,
`Pending Design`, `Approved QA`, `Recently released`), do not
modify it — log a workpad note and stop.

## Workpad layout

```
## Symphony Workpad

`<host>:<abs-workdir>@<short-sha>`

### Plan
- [ ] Reproduce signal
- [ ] Implement <X>
- [ ] Add tests
- [ ] Run quality gates
- [ ] Open PR

### Acceptance Criteria
(mirrored from ticket; one checkbox per item)

### Validation
(commands run, outputs, screenshots if UI-touching)

### Notes
(decisions, blockers, gotchas)
```

Edit this comment in place as work progresses; never add separate
"done" or "summary" comments.

## Hard stops

- Do not modify any path outside the cloned workspace.
- Do not push to `main` directly.
- Do not bypass branch protections, CI, or `--no-verify` git hooks.
- Do not create public artifacts (gists, pastebins) with code.
- If something feels off (auth confusion, repo doesn't match ticket,
  unexpected files), stop and write a blocker note. Do not "try one
  more thing".
