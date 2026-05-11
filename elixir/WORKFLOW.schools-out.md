---
tracker:
  kind: linear
  team_key: SODEV
  routing_label: agent
  active_states:
    - Scheduled
    - In Development
  terminal_states:
    - Released / Live
    - Closed
    - Canceled
    - Duplicate
  on_pickup_state: "In Development"
  on_complete_state: "In QA / Review"
  on_pr_merge_state: null
polling:
  interval_ms: 5000
workspace:
  root: ~/code/schoolsout-workspaces
hooks:
  after_create: |
    # Primary repo at workspace root.
    git clone --depth 1 https://github.com/schoolsoutapp/schools-out .
    # Point origin/HEAD → dev so `gh pr create` defaults to dev (not main).
    # Pre-fetch dev so `git checkout -B ... origin/dev` works without extra fetch.
    git remote set-head origin dev
    git fetch --depth=1 origin dev
    # Frontend repo at ./fe-next-app — eliminates the SODEV-827 class of
    # bugs where the agent had to clone the right repo mid-run after
    # burning turns on the wrong one. Whitelist mirrored in the prompt
    # body's "Allowed repositories" section.
    git clone --depth 1 https://github.com/schoolsoutapp/fe-next-app fe-next-app
    git -C fe-next-app remote set-head origin dev
    git -C fe-next-app fetch --depth=1 origin dev
    if [ -f Gemfile ]; then
      bundle install --quiet || true
    fi
  before_remove: |
    : # no-op (do not modify branches on workspace teardown)
  timeout_ms: 300000
agent:
  max_concurrent_agents: 11
  max_turns: 25
agent_runtime:
  command: $SYMPHONY_AGENT_SHIM_PYTHON -m symphony_agent_shim
  approval_policy: never
  thread_sandbox: workspace-write
  read_timeout_ms: 60000
  turn_sandbox_policy:
    type: workspaceWrite
  # GitHub identity used by the agent's git/gh subprocesses. When all three
  # SYMPHONY_GITHUB_APP_* vars are set, the shim mints an installation token
  # and the agent authors PRs as `symphony-orchestrator[bot]`. If any var is
  # missing, the shim falls back to GH_TOKEN/GITHUB_TOKEN from the operator's
  # environment so older runs keep working. See docs/github-app-setup.md.
  github_app_env:
    - SYMPHONY_GITHUB_APP_ID
    - SYMPHONY_GITHUB_APP_INSTALLATION_ID
    - SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH
server:
  host: 127.0.0.1
  port: 4000
---

# Schools Out — Symphony Workflow

Drive a Linear-tracked ticket on `schoolsoutapp/schools-out` end-to-end:
implement the ticket, run quality gates, push the branch, and open a PR
against `main`. Symphony orchestrates Linear state transitions and workpad
posts for you.

## Ticket prompt

You are working on Linear ticket `{{ issue.identifier }}`.

{% if attempt %}
Continuation attempt #{{ attempt }} — workspace already exists from prior turns.
Resume; do not redo completed work.
{% endif %}

Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Allowed repositories (whitelist)

Both repos are cloned at workspace creation. Touch only these:

- `./` — `schoolsoutapp/schools-out` (Rails backend; default)
- `./fe-next-app/` — `schoolsoutapp/fe-next-app` (Next.js frontend)

If diagnosis points to a repo NOT in this list, STOP and report. Do
NOT clone any other repo.

## PR base branch per repo

Team uses gitflow: the GitHub default branch (`main`) is NOT the
integration branch. PRs target the team's working branch; releases are
cut from there to `main`. Always branch off and PR against the base
branch listed below. Never target `main` unless the repo has no
integration branch.

| Repo | PR base |
| --- | --- |
| `schoolsoutapp/schools-out` | `dev` |
| `schoolsoutapp/fe-next-app` | `dev` |
| `schoolsoutapp/claude-camps-crawler` | `dev` |
| `schoolsoutapp/data-ingestion-admin` | `dev` |
| `schoolsoutapp/temporal-crawler` | `dev` |
| `schoolsoutapp/schoolsout-crawler` | `main` |
| `schoolsoutapp/v0-schools-out` | `main` |
| `schoolsoutapp/terraform-runners` | `main` |
| `schoolsoutapp/data-ingestion-tool` | `master` |

If a repo not listed above ever enters the whitelist, the table must be
updated in the same diff. Do not guess the base branch.

## Mandatory turn-1 deliverable: understanding.md

Before any `Edit` / `Write` / mutating `Bash` call, write
`state/<session>/understanding.md` with three sections:

1. **target_repos** — which whitelisted repo(s) the fix touches. Cite a
   code reference (`path/to/file.ext:line`) or a verified `curl`/`grep`
   output for each. No guessing.
2. **root_cause** — what is wrong and where. Every claim cites a
   file:line. If you catch yourself writing "I think" / "probably" /
   "might" — STOP, verify, rewrite without hedging.
3. **expected_behavior_diff** — smallest possible change. List each
   numbered AC item (`AC#1`, `AC#2`, …) → file(s) you will change.

Each section must contain at least one verified `path/to/file.ext:line`
citation backed by a prior `Read`/`grep`/`curl` call. A section with
section headers but no citations counts as missing — the file existing
is not enough.

Skipping this artifact is a hard stop, not a style preference.

## Operating rules

1. Implement only what the ticket's Acceptance Criteria require.
   - **AC-trace mandatory.** Every changed file maps to a numbered AC
     item from the issue description. PR body lists
     `AC#N → file.ext:line-range` for each AC.
   - **Karpathy / no-drive-by.** Default: inline new logic into the
     existing caller (controller, job, model). Extract to a class,
     service, builder, wrapper, or factory ONLY when call site #2
     already exists in the same diff — if you catch yourself writing a
     new class with 1 caller, stop and inline it instead. Test files do
     not count as a real call site. No quote-style swaps, no
     spontaneous docstrings, no whitespace reformat outside the diff
     scope — preserve the exact formatting of unchanged lines. Adjacent
     tech debt: mention in the PR body, do NOT fix in the same diff.
2. Branch off the target repo's PR base branch (see "PR base branch per
   repo" table above). Run `git fetch origin <base>` then
   `git checkout -B <branch-name> origin/<base>`. Never branch off
   `main` when the table lists a different base. Branch name:
   `agents/sodev-{{ issue.identifier | split: "-" | last }}-<short-slug>`
   (lowercase, dashes).
3. One atomic commit per logical change. Concise descriptive messages.
4. Run quality gates before pushing:
   - **Rails repos** (`Gemfile` present): `bundle exec rubocop --autocorrect-all`; if
     rubocop changes files, stage them and amend the commit; then verify `bundle exec
     rubocop` exits 0.
   - **Next.js / TS repos** (`package.json` present): run `pnpm format` (Prettier
     write-in-place) first — if it changes any files, stage them and amend the last
     commit before continuing. Then run `pnpm lint`; if lint reports errors, run
     `pnpm lint:fix`, re-run `pnpm format` again (ESLint fixes can introduce
     Prettier violations), re-stage, amend, and verify both `pnpm format:check`
     and `pnpm lint` exit 0. Do NOT push with outstanding lint or format violations.
   - Tests for changed files.
5. Push the branch and open a PR with `gh pr create`:
   - **Pre-PR base branch check (mandatory before any `gh pr create` call)**:
     Run `git log --oneline origin/dev..HEAD` (or the repo's base per the
     table). The output must show only your commits. If it is empty or shows
     unrelated history, you branched off the wrong ref — stop, re-branch from
     `origin/dev`, cherry-pick your commits, and verify again before pushing.
   - **Base branch**: pass `--base dev` for `schools-out` and `fe-next-app`
     (see table above). Never omit `--base`. Never PR against `main` unless
     the table says so. A PR with the wrong base must be closed and reopened —
     do not retarget after the fact.
   - Title: `[{{ issue.identifier }}] <one-line>`
   - Body: 2–4 sentence summary + `Linear: {{ issue.url }}`
   - Apply label `symphony` (create with color `#7C3AED` if missing).
   - Do **not** add reviewers via `--reviewer`; the agent's git identity
     is the operator (`viniciuscffreitas`) and GitHub rejects self-review
     with HTTP 422. The operator monitors PRs via the Linear workpad.
   - **Never** call `gh pr merge`. Humans merge.

## Hard stops

- Do not modify paths outside the cloned workspace.
- Do not push to `main` directly. Do not push to any base branch listed
  in the "PR base branch per repo" table directly — always go through a
  PR.
- Do not bypass branch protections, CI, or `--no-verify` git hooks.
- Do not clone any repo not listed in "Allowed repositories" above.
- Do not run `Edit` / `Write` before `state/<session>/understanding.md`
  exists with all three sections populated.
- If auth/permissions/tooling feels off (token errors, repo not found),
  stop. Do not retry blindly. The orchestrator captures your last message
  on the Linear workpad — say what is wrong and exit.

When you finish a clean PR, end your turn with a short summary that
includes the PR URL and `git diff --stat origin/main..HEAD`. Do not call
any Linear API yourself; Symphony moves the issue state and posts the
workpad based on your final message.
