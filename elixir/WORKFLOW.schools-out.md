---
tracker:
  kind: linear
  # Linear project: "Symphony E2E Sandbox" (id 3792a5e9-efa6-4677-83f1-c47cbeacc249)
  # Isolated project for testing Symphony agent runtime end-to-end. Safe to wipe.
  # Do NOT widen the slug to a real delivery project until the agent has landed
  # at least one human-reviewed PR.
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
  on_pickup_state: "In Development"
  on_complete_state: "In QA / Review"
polling:
  interval_ms: 5000
workspace:
  root: ~/code/schoolsout-workspaces
hooks:
  after_create: |
    # Primary repo at workspace root.
    git clone --depth 1 https://github.com/schoolsoutapp/schools-out .
    # Frontend repo at ./fe-next-app — eliminates the SODEV-827 class of
    # bugs where the agent had to clone the right repo mid-run after
    # burning turns on the wrong one. Whitelist mirrored in the prompt
    # body's "Allowed repositories" section.
    git clone --depth 1 https://github.com/schoolsoutapp/fe-next-app fe-next-app
    if [ -f Gemfile ]; then
      bundle install --quiet || true
    fi
  before_remove: |
    : # no-op (do not modify branches on workspace teardown)
agent:
  max_concurrent_agents: 4
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

Skipping this artifact is a hard stop, not a style preference.

## Operating rules

1. Implement only what the ticket's Acceptance Criteria require.
   - **AC-trace mandatory.** Every changed file maps to a numbered AC
     item from the issue description. PR body lists
     `AC#N → file.ext:line-range` for each AC.
   - **Karpathy / no-drive-by.** Do NOT introduce a class, service,
     builder, wrapper, or factory unless it has 2+ real call sites in
     the same diff. No quote-style swaps, no spontaneous docstrings, no
     whitespace reformat outside the diff scope. Adjacent tech debt:
     mention in the PR body, do NOT fix in the same diff.
2. Branch off latest `origin/main`. Branch name:
   `agents/sodev-{{ issue.identifier | split: "-" | last }}-<short-slug>`
   (lowercase, dashes).
3. One atomic commit per logical change. Concise descriptive messages.
4. Run quality gates before pushing:
   - Lint / static checks (`bundle exec rubocop`, `yarn lint` — pick from
     `Gemfile` / `package.json`).
   - Tests for changed files.
5. Push the branch and open a PR with `gh pr create`:
   - Title: `[{{ issue.identifier }}] <one-line>`
   - Body: 2–4 sentence summary + `Linear: {{ issue.url }}`
   - Apply label `symphony` (create with color `#7C3AED` if missing).
   - Do **not** add reviewers via `--reviewer`; the agent's git identity
     is the operator (`viniciuscffreitas`) and GitHub rejects self-review
     with HTTP 422. The operator monitors PRs via the Linear workpad.
   - **Never** call `gh pr merge`. Humans merge.

## Hard stops

- Do not modify paths outside the cloned workspace.
- Do not push to `main` directly.
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
