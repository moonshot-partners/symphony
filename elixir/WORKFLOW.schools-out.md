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

## Operating rules

1. Implement only what the ticket's Acceptance Criteria require. No
   out-of-scope changes.
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
   - Request review from `viniciuscffreitas`.
   - **Never** call `gh pr merge`. Humans merge.

## Hard stops

- Do not modify paths outside the cloned workspace.
- Do not push to `main` directly.
- Do not bypass branch protections, CI, or `--no-verify` git hooks.
- If auth/permissions/tooling feels off (token errors, repo not found),
  stop. Do not retry blindly. The orchestrator captures your last message
  on the Linear workpad — say what is wrong and exit.

When you finish a clean PR, end your turn with a short summary that
includes the PR URL and `git diff --stat origin/main..HEAD`. Do not call
any Linear API yourself; Symphony moves the issue state and posts the
workpad based on your final message.
