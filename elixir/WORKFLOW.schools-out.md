---
tracker:
  kind: linear
  label: agent
  active_states:
    - Scheduled
    - In Development
  terminal_states:
    - Released / Live
    - Closed
    - Canceled
    - Cancelled
    - Duplicate
  in_progress_states:
    - In Development
  review_state: In Code Review
  ready_state: Approved QA
  blocked_state: On Hold / Blocked
  done_extra_states:
    - Recently released
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

Workspace:

The workspace starts with `schools-out` (Rails backend, at the root) and
`fe-next-app` (Next.js frontend, in `./fe-next-app/`) already cloned on `dev`.
`schools-out` is the shared backend for every product. Decide which product
this ticket belongs to from its title, description, and labels, then make sure
that product's repositories are present before you start. Clone any that are
missing with `git clone --depth 1 https://github.com/schoolsoutapp/<repo> <dir>`
(git authentication is already configured) and check out `dev`.

Product to repository map:

- Parents app, SEO, web frontend: `fe-next-app` (already present) plus the
  `schools-out` backend.
- New Maestro: the `claude-camps-crawler` repo (its `claude-workflow/` is the
  Next.js admin UI; its `claude-worker/` is the Python worker), the
  `temporal-crawler` repo (Python + Temporal crawler), and the `schools-out`
  backend (already present, receives ingestion via the Internal API).
- Old Maestro (being retired): `data-ingestion-admin` only when the ticket
  explicitly targets it.

Read each repository's own `AGENTS.md` / `README` before changing it, keep
changes scoped to the repositories the ticket actually requires, and install
dependencies only for the repositories you actually edit.

Ticket lifecycle:

You drive this ticket's Linear state with the `linear_graphql` tool (it carries
Symphony's Linear auth; see the `linear` skill). Symphony picks up tickets in
`Scheduled` and `In Development` and never moves them itself, only reads state.
Those two are the "agent is on it" states. Always fetch the team's workflow
states first to get the exact `stateId`, then `issueUpdate`.

- When you start, move the ticket from `Scheduled` to `In Development` so the
  team sees it is being worked. Keep going across turns until the work is done;
  `In Development` stays active, so if a turn is interrupted Symphony re-engages
  you to continue from the same workspace.
- When you open the PR, attach it with `attachmentLinkGitHubPR` and move the
  ticket to `In Code Review`. That takes it out of the active states and ends
  the run cleanly.
- If you are genuinely blocked and cannot finish, move the ticket to
  `On Hold / Blocked` and comment what is blocking it. That also ends the run.
- Never stop while still in `Scheduled` or `In Development` unless you have an
  open PR or a real blocker; otherwise you will simply be re-dispatched.

Proof of work (PR evidence):

Reviewers approve from the PR, so put the proof there.

- For changes users can see (UI, pages, components, styles): capture a
  screenshot of the working result with Playwright against the running app
  (and the broken state first when the ticket is a bug). Save the images under
  `qa-evidence/` in the workspace. `qa-evidence/` is gitignored, so they are
  silently skipped by a normal `git add` and never reach the PR — stage them
  explicitly with `git add -f qa-evidence/<files>` and commit them on the PR
  branch. The repo is private, so `raw.githubusercontent.com` and blob image
  URLs do NOT render inline in a PR description (GitHub's image proxy cannot
  read private repos), and relative paths are not resolved in PR bodies. Do not
  embed them as inline images. Instead, under a `## QA Evidence` heading, link
  each committed screenshot by its full blob URL at the PR's head commit so the
  reviewer can open it, e.g.
  `- [Parents signup typo suggestion](https://github.com/<owner>/<repo>/blob/<branch-or-sha>/qa-evidence/<file>.png)`.
  The committed images also render directly in the PR's Files changed tab,
  which is the reliable proof for a private repo. If the repo already has a
  Playwright or e2e setup, use it; otherwise drive the dev server with a small
  Playwright script.
- For backend, config, or non-visual changes: state in the PR what you ran to
  verify it (tests, build, type-check) and paste the relevant output. Do not
  fabricate screenshots.

Keep it honest and minimal: real proof a reviewer can check, not ceremony.

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
