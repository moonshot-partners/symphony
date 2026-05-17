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
  on_complete_state: "In Code Review"
  on_pr_merge_state: "Ready for QA"
polling:
  interval_ms: 5000
workspace:
  root: ~/code/schoolsout-workspaces
hooks:
  after_create: |
    # Gate A — install integrity: fail loudly on any non-zero exit. The hook
    # used to mask install failures with `|| true`, which let a half-populated
    # node_modules through and turned every downstream `npm test`/QA run into
    # a silent BLOCKED. `NPM_CONFIG_IGNORE_SCRIPTS=1` is already injected by
    # Symphony's hook runner (Workspace.hook_env/0) so postinstall scripts
    # like @sentry/cli don't run here and corrupt the install when their
    # secrets aren't present.
    set -euo pipefail
    # Primary repo at workspace root.
    git clone --depth 1 -b dev https://github.com/schoolsoutapp/schools-out .
    # Clone lands on `dev` so AGENTS.md/CLAUDE.md (committed to dev, not main)
    # are readable at Step 0 before any branching. The explicit fetch below
    # ensures origin/dev ref exists even if git's shallow clone omits it.
    git fetch --depth=1 origin dev:refs/remotes/origin/dev
    git remote set-head origin dev
    # Frontend repo at ./fe-next-app — eliminates the SODEV-827 class of
    # bugs where the agent had to clone the right repo mid-run after
    # burning turns on the wrong one. Whitelist mirrored in the prompt
    # body's "Allowed repositories" section.
    git clone --depth 1 -b dev https://github.com/schoolsoutapp/fe-next-app fe-next-app
    # Same as above: clone dev so AGENTS.md is in the working tree at Step 0.
    git -C fe-next-app fetch --depth=1 origin dev:refs/remotes/origin/dev
    git -C fe-next-app remote set-head origin dev
    # fe-next-app is an npm project (versions package-lock.json). Install deps
    # here with `npm ci` — if `pnpm install` runs later it builds a strict
    # node_modules that fails undeclared transitive imports (e.g.
    # @amplitude/analytics-core), which 500s `next dev` and blocks rule-5 QA.
    (cd fe-next-app && npm ci --no-audit --no-fund)
    # Gate A — verify the install actually produced a working test toolchain.
    # If jest can't enumerate its tests, node_modules is half-provisioned and
    # the agent would crash later in `npm test`/`qa_check.py` with no signal
    # back to Symphony. Fail the workspace creation instead, loud.
    (cd fe-next-app && npx --no-install jest --listTests > /dev/null)
    if [ -f Gemfile ]; then
      # Install gems into vendor/bundle so Docker can find them at /workspace/vendor/bundle.
      bundle config set --local path vendor/bundle
      # --no-color (not --quiet) so the error message survives in the hook
      # output buffer when bundle exits non-zero. --quiet swallows the one
      # diagnostic line we need to debug auth/native-extension failures.
      bundle install --no-color
    fi
  before_remove: |
    : # no-op (do not modify branches on workspace teardown)
  # Two clones + `npm ci` (fe-next-app) + `bundle install` (Rails) — give it
  # room so a slow install doesn't leave a half-provisioned workspace.
  timeout_ms: 600000
agent:
  max_concurrent_agents: 11
  max_turns: 25
agent_runtime:
  command: $SYMPHONY_AGENT_SHIM_PYTHON -m symphony_agent_shim
  docker_image: schoolsout-base:latest
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
qa:
  # Path inside the workspace where view-layer tests drop the QA evidence
  # bundle (screenshots, session.webm, qa-report.md). Symphony reads this dir
  # post-PR and posts the bundle to the Linear ticket. Schools-out keeps its
  # frontend in ./fe-next-app, so evidence lands at fe-next-app/qa-evidence/.
  evidence_subpath: fe-next-app/qa-evidence
---

# Schools Out — Symphony Workflow

Drive a Linear-tracked ticket on `schoolsoutapp/*` end-to-end. The
per-repo `AGENTS.md` files are the source of truth for the agent
process — read them on turn 1 before any code or branch.

## Ticket prompt

You are working on Linear ticket `{{ issue.identifier }}`.

{% if attempt %}
Continuation attempt #{{ attempt }} — workspace already exists from prior
turns. Resume; do not redo completed work.
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

If diagnosis points to a repo NOT in this list, STOP and report.

## Step 0 — Read `AGENTS.md` before any code

Each repo's `AGENTS.md` carries the full agent process (AC Extracted
turn-1 post, `understanding.md`, operating rules, UI QA self-review,
PR conventions, hard stops, final-turn summary). Read it on turn 1
for every repo you touch:

```
cat AGENTS.md
cat fe-next-app/AGENTS.md
```

Precedence, highest first: (1) repo `AGENTS.md`/`CLAUDE.md`, (2) this
workflow, (3) the Linear ticket, (4) framework defaults. A ticket
that conflicts with `AGENTS.md` is a ticket bug — note it in
`understanding.md` under `root_cause` and follow the repo convention.
