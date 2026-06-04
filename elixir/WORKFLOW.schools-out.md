---
tracker:
  kind: linear
  label: agent
  active_states:
    - In Development
  terminal_states:
    - Released / Live
    - Closed
    - Canceled
    - Cancelled
    - Duplicate
polling:
  interval_ms: 5000
workspace:
  root: ~/code/schoolsout-workspaces
hooks:
  after_create: |
    set -eu

    git clone --depth 1 --branch dev https://github.com/schoolsoutapp/schools-out .
    git clone --depth 1 --branch dev https://github.com/schoolsoutapp/fe-next-app fe-next-app

    if [ -f Gemfile ]; then
      bundle config set --local path vendor/bundle
      bundle install --no-color
    fi

    if [ -f fe-next-app/package.json ]; then
      cd fe-next-app
      if [ -f pnpm-lock.yaml ] && command -v pnpm >/dev/null 2>&1; then
        pnpm install --frozen-lockfile
      elif [ -f package-lock.json ]; then
        npm ci --no-audit --no-fund
      else
        npm install --no-audit --no-fund
      fi
    fi
  before_run: |
    set -eu
    git fetch origin dev
    git status --short
    if [ -d fe-next-app/.git ]; then
      cd fe-next-app
      git fetch origin dev
      git status --short
    fi
  before_remove: |
    : # Workspace cleanup only; do not mutate GitHub or Linear from teardown.
  timeout_ms: 600000
agent:
  max_concurrent_agents: 4
  max_turns: 25
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
server:
  host: 127.0.0.1
  port: 4010
---

You are working on Linear ticket `{{ issue.identifier }}` for SchoolsOut.

Source of truth:

1. Use the checked-out SchoolsOut repositories as the source of truth.
2. Read the relevant repository instructions before changing code:
   - `./AGENTS.md` for `schoolsoutapp/schools-out`
   - `./fe-next-app/AGENTS.md` for `schoolsoutapp/fe-next-app`
3. Follow each repository's own scripts, tests, branch conventions, and PR conventions.
4. Keep changes scoped to the ticket and to the repository or repositories the ticket actually requires.
5. Do not edit files outside the Symphony workspace.
6. Do not invent Symphony-specific gates, workpads, or policy ceremony unless the repository instructions explicitly require them.

Issue:

Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
State: {{ issue.state }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

{% if attempt %}
This is retry attempt #{{ attempt }}. Resume from the existing workspace and avoid repeating completed work unless the current state requires it.
{% endif %}

Complete the ticket end to end when possible. If blocked by missing credentials, permissions, or an untestable requirement, report the exact blocker and stop.
