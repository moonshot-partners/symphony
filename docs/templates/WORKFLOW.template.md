---
# Template for a per-project Symphony workflow file.
#
# Copy this into your Symphony install as `WORKFLOW.<project>.md`
# (lowercase, hyphens) and fill in every <PLACEHOLDER>. The schools-out
# reference lives at `elixir/WORKFLOW.schools-out.md` — borrow patterns
# from it when stuck.
#
# Pointer: launch Symphony with `SYMPHONY_WORKFLOW_FILE=/path/to/this`
# or pass the path on the command line.

tracker:
  kind: linear
  # Issue prefix in the tracker (the part before the dash in IDs).
  team_key: <TEAM_KEY>
  # Label that flags an issue as agent-ready.
  routing_label: agent
  # States Symphony polls for candidate work. The first entry is the
  # state the operator moves a ticket to in order to dispatch.
  active_states:
    - Scheduled
    - In Development
  # States Symphony treats as final — it never re-picks-up a ticket in
  # one of these.
  terminal_states:
    - Released / Live
    - Closed
    - Canceled
    - Duplicate
  # Where Symphony moves a ticket when it claims it.
  on_pickup_state: "In Development"
  # Where Symphony moves a ticket when the agent opens a clean PR.
  on_complete_state: "In Code Review"
  # Where Symphony moves a ticket when the PR merges.
  on_pr_merge_state: "Ready for QA"
  # Where Symphony moves a ticket on reject (Gate failure, red CI,
  # undisclosed off-allowlist diff, QA BLOCKED, etc.).
  on_reject_state: "On Hold / Blocked"
  # Where Symphony moves a ticket when the agent hits the turn cap
  # with a green PR (env-blocked, not a rejection). Falls back to
  # on_reject_state when there is no PR or CI is red.
  on_exhaust_state: "In Code Review"

polling:
  interval_ms: 5000

workspace:
  # Host path Symphony writes per-ticket workspaces into. Make sure
  # the host service user owns it and the agent container's user has
  # the same UID/GID (Step 1 of `docs/ONBOARDING.md`).
  root: <WORKSPACE_ROOT>          # e.g. ~/code/<project>-workspaces

repos:
  # PRIMARY repo. Cloned at the workspace root (`path: .`).
  - url: <PRIMARY_REPO_URL>       # e.g. https://github.com/<org>/<repo>
    branch: <DEFAULT_BRANCH>      # usually `dev` or `main`
    path: .
    install: |
      # Shell that runs after clone, inside the workspace.
      #
      # Tools called here must already exist in the Docker image
      # named at agent_runtime.docker_image (Step 1 of onboarding).
      #
      # Typical contents: fetch the default-branch ref so it is
      # available locally, then install dependencies.
      #
      # Example (Ruby + Rails):
      #
      #   git fetch --depth=1 origin <DEFAULT_BRANCH>:refs/remotes/origin/<DEFAULT_BRANCH>
      #   git remote set-head origin <DEFAULT_BRANCH>
      #   if [ -f Gemfile ]; then
      #     docker run --rm \
      #       -v "$(pwd):/workspace" -w /workspace \
      #       <PROJECT>-base:latest \
      #       bash -c "bundle config set --local path vendor/bundle && bundle install --no-color"
      #   fi
      :
    # Optional smoke check that runs before the agent boots. Exit
    # non-zero to abort the dispatch.
    # verify: <SMOKE_CHECK_COMMAND>

  # SECONDARY repos (optional). Whitelist every repo the agent is
  # allowed to touch — anything outside the list trips the
  # ConflictDisclosure gate.
  #
  # - url: <SECONDARY_REPO_URL>
  #   branch: <DEFAULT_BRANCH>
  #   path: <SUBDIRECTORY>        # cloned under workspace/<path>
  #   install: |
  #     git fetch --depth=1 origin <DEFAULT_BRANCH>:refs/remotes/origin/<DEFAULT_BRANCH>
  #     git remote set-head origin <DEFAULT_BRANCH>
  #     npm ci --no-audit --no-fund

hooks:
  # Runs before Symphony deletes the workspace at the end of a
  # dispatch. Default no-op; override if you need to push branches,
  # archive artifacts, etc.
  before_remove: |
    :
  # Outer timeout for the whole install pipeline. Multi-repo clones
  # + bundle install + npm ci can be slow — give it room.
  timeout_ms: 600000

agent:
  # Max simultaneous agent containers on this Symphony host. Calibrate
  # to the host's CPU/RAM; schools-out runs 4 on a Hetzner box.
  max_concurrent_agents: 4
  # Turn cap per dispatch. The agent must finish the ticket within
  # this many turn-end messages. Hit the cap with a green PR →
  # on_exhaust_state; hit it without → on_reject_state.
  max_turns: 25

agent_runtime:
  # Entry point Symphony invokes for each turn. The default below
  # uses the Python shim that ships with Symphony.
  command: $SYMPHONY_AGENT_SHIM_PYTHON -m symphony_agent_shim
  # Docker image from Step 1 of onboarding.
  docker_image: <PROJECT>-base:latest
  # Approval policy passed to the agent SDK. `never` is the
  # recommended default for autonomous runs.
  approval_policy: never
  # Sandbox the agent's filesystem to the workspace. Edits outside
  # are blocked at the SDK level.
  thread_sandbox: workspace-write
  # Per-turn read timeout. 60s catches stalls without false positives
  # on long compiles.
  read_timeout_ms: 60000
  turn_sandbox_policy:
    type: workspaceWrite
  # GitHub identity used by the agent's git/gh subprocesses.
  # When all three vars are set, the shim mints an installation
  # token and PRs are authored by `<app>[bot]`. Missing any one of
  # them → falls back to GH_TOKEN / GITHUB_TOKEN.
  github_app_env:
    - SYMPHONY_GITHUB_APP_ID
    - SYMPHONY_GITHUB_APP_INSTALLATION_ID
    - SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH
  # Branch name regex enforced at `git push` time. The default
  # below covers `<type>/<TEAM>-<N>[-slug]` for the conventional
  # types — Symphony allows `agents/` as the canonical agent prefix
  # plus the standard conventional-commit types.
  branch_naming_pattern: "^(feat|fix|chore|docs|refactor|test|ci|agents)/(<TEAM_KEY>)-[0-9]+(-[a-z0-9-]+)?$"

qa:
  # Path(s) inside the workspace where the agent drops QA artifacts
  # (`<path>/qa-evidence/*.png`, `*.webm`, `*.zip`). Symphony reads
  # each path post-PR, merges the files, and posts a single bundle to
  # the workpad. Use a single string for one path, a list for many.
  evidence_subpath: qa-evidence
  # Multi-path example (frontend + backend artifacts in different
  # subdirs):
  #
  # evidence_subpath:
  #   - fe-next-app/qa-evidence
  #   - qa-evidence
---

# <PROJECT> — Symphony workflow

Drive a tracker-tracked ticket on `<org>/*` end-to-end. The per-repo
`AGENTS.md` files are the source of truth for the agent process — read
them on turn 1 before any code or branch.

## Rule Enforcement Map

Every rule below carries either `[enforced-by: <mechanism>]` (a CI
job, PreToolUse hook, or orchestrator gate halts the run on violation)
or `[advisory]` (prose-only; honor system). Per SYM-1e, no silent
Layer-B rules — when adding a new rule, assign one tag here.

| Rule | Enforcement |
|------|-------------|
| First turn-end message starts with `## AC Extracted` or `## BLOCKED: AC not testable` | enforced-by: `SymphonyElixir.Orchestrator.GateCEnforcement` |
| Continuation attempts still post the turn-1 header | enforced-by: `SymphonyElixir.Orchestrator.GateCEnforcement` |
| Touch only repos in the "Allowed repositories" whitelist | enforced-by: agent sandbox `workspace-write` + advisory for off-list `git clone` |
| Step 0 — Read each repo's `AGENTS.md` on turn 1 | advisory |
| Precedence (repo `AGENTS.md` > this workflow > ticket > framework defaults) | advisory |
| PR follow-up: open PR detected → continue on its branch, do not open a second PR | advisory |

## Ticket prompt

You are working on tracker ticket `{{ issue.identifier }}`.

## Hard requirement — first turn-end message [enforced-by: orchestrator GateCEnforcement]

Your very first turn-end message in this session **must** start with
one of these two headers, before any other tool use or code:

- `## AC Extracted` — followed by a numbered list of binary,
  testable acceptance criteria derived from the ticket description
  (see the `AGENTS.md` of the repo you are touching for the exact
  format).
- `## BLOCKED: AC not testable` — followed by the reason, when the
  description does not contain a testable contract.

This applies on every dispatch, including continuation attempts. Do
not assume a prior run already posted it — each agent session is
fresh and must satisfy this contract on its own first turn. Gate C
halts the run if neither header appears, with no further retries.

{% if attempt %}
Continuation attempt #{{ attempt }} — workspace already exists from
prior turns. Resume; do not redo completed work. The hard requirement
above still applies; post the header before resuming.
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

All repos in this list are cloned at workspace creation. Touch only
these:

- `./` — `<org>/<PRIMARY_REPO>` (primary)
<!-- Add one line per secondary repo from the `repos:` block above. -->
<!-- - `./<SUBDIRECTORY>/` — `<org>/<SECONDARY_REPO>` -->

If diagnosis points to a repo NOT in this list, STOP and report.

## Step 0 — Read `AGENTS.md` before any code [advisory]

Each repo's `AGENTS.md` carries the full agent process (AC Extracted
turn-1 post, `understanding.md`, operating rules, QA self-review, PR
conventions, hard stops, final-turn summary). Read it on turn 1 for
every repo you touch:

```
cat AGENTS.md
<!-- cat <SUBDIRECTORY>/AGENTS.md -->
```

Precedence, highest first: (1) repo `AGENTS.md` / `CLAUDE.md`,
(2) this workflow, (3) the tracker ticket, (4) framework defaults. A
ticket that conflicts with `AGENTS.md` is a ticket bug — note it in
`understanding.md` under `root_cause` and follow the repo
convention.

{% if issue.has_pr_attachment %}
## PR follow-up — open PR detected [advisory]

An open PR already exists for `{{ issue.identifier }}`. **Do not
create a new branch or a second PR.**

Find the existing PR and continue on its branch:

```
gh pr list --repo <org>/<PRIMARY_REPO> --search "{{ issue.identifier }}" --json number,headRefName
<!-- gh pr list --repo <org>/<SECONDARY_REPO> --search "{{ issue.identifier }}" --json number,headRefName -->
gh pr checkout <NUMBER>
gh pr view <NUMBER> --comments
```

Fix every **Critical Issue** from the automated review, then
`git push` — the open PR updates automatically.
{% endif %}
