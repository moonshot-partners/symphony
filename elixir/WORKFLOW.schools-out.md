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
  on_reject_state: "On Hold / Blocked"
polling:
  interval_ms: 5000
workspace:
  root: ~/code/schoolsout-workspaces
repos:
  # Primary Rails backend at workspace root. Post-clone: ensure origin/dev ref
  # exists (shallow clones may omit it) and install gems when present.
  # NPM_CONFIG_IGNORE_SCRIPTS=1 is already injected by Symphony's hook runner
  # so postinstall scripts (e.g. @sentry/cli) don't corrupt the install.
  - url: https://github.com/schoolsoutapp/schools-out
    branch: dev
    path: .
    install: |
      git fetch --depth=1 origin dev:refs/remotes/origin/dev
      git remote set-head origin dev
      if [ -f Gemfile ]; then
        # No -u override: the image's default USER is `ubuntu` (UID 1000),
        # matching the host symphony user. `-u root` made `bundle install`
        # write `.bundle/` and `vendor/bundle/` as root into the bind-mounted
        # workspace; the next dispatch then failed `File.rm_rf!` on the
        # zombie-reset path with :eexist (symphony runs as ubuntu, cannot
        # remove root-owned files). bundle install is fully workspace-local
        # (--path vendor/bundle), so it never needed root.
        docker run --rm \
          -v "$(pwd):/workspace" -w /workspace \
          schoolsout-base:latest \
          bash -c "bundle config set --local path vendor/bundle && bundle install --no-color"
      fi
  # Frontend Next.js repo — pre-cloned to avoid SODEV-827 class of bugs where
  # the agent burned turns cloning the wrong repo mid-run. Whitelist mirrored
  # in the prompt body's "Allowed repositories" section.
  - url: https://github.com/schoolsoutapp/fe-next-app
    branch: dev
    path: fe-next-app
    install: |
      git fetch --depth=1 origin dev:refs/remotes/origin/dev
      git remote set-head origin dev
      npm ci --no-audit --no-fund
      # NEXT_PUBLIC_GOOGLE_MAPS_API_KEY must be injected via the
      # orchestrator's environment (systemd unit on Hetzner exports it,
      # System.cmd/3 inherits it into the hook shell). Never inline the
      # literal value here — this workflow file lives in a public repo.
      # If the env var is unset, .env.local is written with an empty
      # value: `next build` still succeeds but the map renders broken,
      # and the agent must not chase that as a bug (SODEV-840).
      printf 'NEXT_PUBLIC_GOOGLE_MAPS_API_KEY=%s\n' "${NEXT_PUBLIC_GOOGLE_MAPS_API_KEY:-}" > .env.local
    verify: npx --no-install jest --listTests > /dev/null
hooks:
  before_remove: |
    : # no-op (do not modify branches on workspace teardown)
  # Two clones + npm ci + optional bundle install — give it room.
  timeout_ms: 600000
agent:
  max_concurrent_agents: 4
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
  # Paths inside the workspace where tests drop QA evidence bundles
  # (screenshots, session.webm, qa-report.md). Symphony reads each dir
  # post-PR, merges the files, and posts a single bundle to the Linear
  # ticket. Frontend tickets emit at fe-next-app/qa-evidence/; backend-only
  # tickets emit at qa-evidence/ at the repo root (rspec output + curl
  # transcripts). When a ticket touches both layers, both dirs are merged.
  # String form (single path) and list form (multi-path) both accepted.
  evidence_subpath:
    - fe-next-app/qa-evidence
    - qa-evidence
---

# Schools Out — Symphony Workflow

Drive a Linear-tracked ticket on `schoolsoutapp/*` end-to-end. The
per-repo `AGENTS.md` files are the source of truth for the agent
process — read them on turn 1 before any code or branch.

## Rule Enforcement Map

Every rule below carries either `[enforced-by: <mechanism>]` (a CI job,
PreToolUse hook, or orchestrator gate halts the run on violation) or
`[advisory]` (prose-only; honor system). Per SYM-1e, no silent Layer-B
rules — when adding a new rule, assign one tag in this table.

| Rule | Enforcement |
|------|-------------|
| First turn-end message starts with `## AC Extracted` or `## BLOCKED: AC not testable` | enforced-by: `SymphonyElixir.Orchestrator.GateCEnforcement` (halts run + parks issue) |
| Continuation attempts still post the turn-1 header | enforced-by: `SymphonyElixir.Orchestrator.GateCEnforcement` (every dispatch is fresh) |
| Touch only repos in the "Allowed repositories" whitelist | enforced-by: agent sandbox `workspace-write` (filesystem) + advisory for `git clone` of off-list URLs |
| Step 0 — Read each repo's `AGENTS.md` on turn 1 | advisory |
| Precedence (repo `AGENTS.md` > this workflow > Linear ticket > framework defaults) | advisory |
| PR follow-up: open PR detected → continue on its branch, do not open a second PR | advisory |

## Ticket prompt

You are working on Linear ticket `{{ issue.identifier }}`.

## Hard requirement — first turn-end message [enforced-by: orchestrator GateCEnforcement]

Your very first turn-end message in this session **must** start with one
of these two headers, before any other tool use or code:

- `## AC Extracted` — followed by a numbered list of binary, testable
  acceptance criteria derived from the ticket description (see the
  `AGENTS.md` of the repo you are touching for the exact format).
- `## BLOCKED: AC not testable` — followed by the reason, when the
  description does not contain a testable contract.

This applies on every dispatch, including continuation attempts. Do not
assume a prior run already posted it — each agent session is fresh and
must satisfy this contract on its own first turn. Gate C halts the run
if neither header appears, with no further retries.

{% if attempt %}
Continuation attempt #{{ attempt }} — workspace already exists from prior
turns. Resume; do not redo completed work. The hard requirement above
still applies; post the header before resuming.
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

## Allowed repositories (whitelist) [enforced-by: agent sandbox workspace-write + advisory for clones]

Both repos are cloned at workspace creation. Touch only these:

- `./` — `schoolsoutapp/schools-out` (Rails backend; default)
- `./fe-next-app/` — `schoolsoutapp/fe-next-app` (Next.js frontend)

If diagnosis points to a repo NOT in this list, STOP and report.

## Step 0 — Read `AGENTS.md` before any code [advisory]

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

{% if issue.has_pr_attachment %}
## PR follow-up — open PR detected [advisory]

An open PR already exists for `{{ issue.identifier }}`. **Do not create a new branch or a second PR.**

Find the existing PR and continue on its branch:

```
gh pr list --repo schoolsoutapp/fe-next-app --search "{{ issue.identifier }}" --json number,headRefName
gh pr list --repo schoolsoutapp/schools-out   --search "{{ issue.identifier }}" --json number,headRefName
gh pr checkout <NUMBER>
gh pr view <NUMBER> --comments
```

Fix every **Critical Issue** from the automated review, then `git push` — the open PR updates automatically.
{% endif %}
