# Onboarding a new project to Symphony

Symphony is **configurable per project, not plug and play.** The
orchestrator core (Gate C / Gate D / `WORKFLOW.<name>.md` resolver /
`qa.evidence_subpath` knob) is genuinely project-agnostic, but
pointing it at a new codebase still requires four artifacts that the
operator must build by hand:

1. A base Docker image that carries the project's toolchain.
2. A `WORKFLOW.<project>.md` describing tracker, repos, hooks, and
   agent runtime for that project.
3. A per-repo `AGENTS.md` for every repo Symphony is allowed to touch.
4. Tracker configuration: labels, state names, and a token with the
   right scope.

This document is the step-by-step. Templates for steps 2 and 3 live
in [`docs/templates/`](./templates/).

The reference implementation of every step is the schools-out setup
already in this repository — `elixir/WORKFLOW.schools-out.md` and the
`schoolsout-base` Docker image. Read the template first, then borrow
from schools-out when stuck.

## Prerequisites

- Symphony already runs somewhere (laptop or VPS — see
  [`elixir/DEPLOYMENT.md`](../elixir/DEPLOYMENT.md)).
- You have admin access to the project's source forge (GitHub) and
  to its issue tracker (Linear today; other adapters TBD).
- You can build and push a Docker image the host that runs Symphony
  can pull (local registry, GHCR, ECR — any reachable tag).

## Step 1 — Base Docker image

The agent runs inside a container the workflow names under
`agent_runtime.docker_image`. The image must carry **every tool the
agent's hooks (`repos[].install`, `repos[].verify`, lint, tests)
invoke at runtime.** This step cannot be templated — what goes in the
image is project-specific. Example from schools-out:

- Ubuntu base + `ubuntu` user UID 1000 (matches the symphony service
  user on the host, so workspace bind-mounts stay writable).
- Ruby 3.4 + `bundle`.
- Node 20 + `pnpm` + `npm`.
- `gh` CLI, `git`, `curl`.

Build the image, tag it (`<project>-base:latest`), and verify the
host running Symphony can resolve the tag (`docker image ls`).

Pick a UID/GID that matches the host service user. The schools-out
image runs as `ubuntu` UID 1000 because Symphony on Hetzner runs as
the host `ubuntu` user — mismatched UIDs left root-owned files inside
the bind-mounted workspace and the next dispatch failed `File.rm_rf!`
on cleanup.

## Step 2 — `WORKFLOW.<project>.md`

Copy [`docs/templates/WORKFLOW.template.md`](./templates/WORKFLOW.template.md)
into your Symphony install as `WORKFLOW.<project>.md` (lowercase,
hyphens). Fill in every `<PLACEHOLDER>`:

- `tracker.team_key` — the issue prefix (e.g. `SODEV`, `PB`).
- `tracker.routing_label` — the label that flags an issue as
  agent-ready (default `agent`).
- `tracker.active_states`, `on_pickup_state`, `on_complete_state`,
  `on_pr_merge_state`, `on_reject_state`, `on_exhaust_state` — names
  must match the tracker exactly. Create the states in Linear before
  Symphony tries to transition into them.
- `workspace.root` — host path Symphony writes workspaces into.
- `repos[]` — every repo the agent is allowed to clone. The first
  entry is the primary; secondary entries clone into subpaths
  (`path:`). Each entry takes an `install:` (multi-line shell run
  after clone) and an optional `verify:` (smoke check before the
  agent starts working).
- `agent_runtime.docker_image` — the tag built in Step 1.
- `agent_runtime.branch_naming_pattern` — the regex enforced at
  `git push` time. The default in the template covers
  `<type>/<TEAM>-<N>[-slug]` for the conventional types.
- `qa.evidence_subpath` — list of in-workspace paths where the agent
  drops `qa-evidence/*` artifacts. Symphony reads these post-PR and
  posts them to the ticket. Use a single string for one path, a list
  for many.

Point Symphony at the file with the `SYMPHONY_WORKFLOW_FILE` env var
or pass the path on the command line (see `elixir/README.md`).

## Step 3 — Per-repo `AGENTS.md`

Symphony enforces a small set of contracts on every ticket
(turn-1 `## AC Extracted`, final-turn `## AC Evidence`, conflict
disclosure on off-allowlist diffs, branch naming, QA self-review).
Those contracts must appear in the AGENTS.md of every repo the agent
touches — that is the file the agent reads on turn 1 before any code.

Copy [`docs/templates/AGENTS.template.md`](./templates/AGENTS.template.md)
into the **target repo** (not into Symphony) as `AGENTS.md` at the
repo root, and fill in stack-specific blocks: language and framework,
test/lint commands, branch policy, hard rules unique to the codebase.

If the repo already has an `AGENTS.md`, **extend it** — do not
overwrite. The template's `## Rule Enforcement Map` section is the
required structure; keep every Symphony-enforced row.

Repeat for every repo in `repos[]`.

## Step 4 — Tracker configuration

Symphony reads from one tracker per workflow. Today that is Linear.
The workflow's `tracker:` block names states by their human-readable
name in the tracker UI, so they must exist before Symphony tries to
transition into them.

For Linear:

- Create the workflow states named in
  `active_states` / `on_pickup_state` / `on_complete_state` /
  `on_pr_merge_state` / `on_reject_state` / `on_exhaust_state`.
- Create the routing label (`agent` by default) and apply it to the
  test ticket.
- Mint a personal API key in Linear Settings → Security & access →
  Personal API keys, export it as `LINEAR_API_KEY`.

For the GitHub side:

- Pick GitHub App auth (`SYMPHONY_GITHUB_APP_ID` +
  `SYMPHONY_GITHUB_APP_INSTALLATION_ID` +
  `SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH`) or a personal access token
  (`GH_TOKEN`). The App path is preferred — see
  [`elixir/docs/github-app-setup.md`](../elixir/docs/github-app-setup.md).
- Add the App / token's user as a collaborator with **write access**
  to every repo in `repos[]`.

The token-management mechanics for multiple projects on the same
Symphony install are tracked in a separate ticket (see SYM-11 "Out
of scope").

## Step 5 — Smoke-dispatch one ticket

Pick a small, low-stakes ticket in the new project. Move it to the
first `active_states` entry (`Scheduled` in the template) and apply
the routing label. Watch the Symphony logs for:

- Workspace creation succeeds (`hooks.before_remove`, install
  scripts exit 0).
- Agent starts and posts turn-1 `## AC Extracted` to the workpad.
- Agent opens a PR on the repo's default branch (the template uses
  `dev` — change if the repo uses `main`).
- Symphony transitions the ticket to `on_complete_state` after the
  PR opens.

If any of those steps fails, fix the workflow / image / AGENTS.md
and re-dispatch the same ticket — same procedure as
[`TICKET-PLAYBOOK.md`](../TICKET-PLAYBOOK.md): edit the description
with what to retry, move the card back to `Scheduled`.

## What is genuinely "agnostic"

The orchestrator core does not need to change per project:

- `WORKFLOW.<name>.md` drives tracker, repos, agent runtime, and QA
  paths.
- Gate C (`## AC Extracted`), Gate D (`## AC Evidence`), conflict
  disclosure, branch naming, QA artifact gate — all pure boundaries
  that read the workflow and the agent's posts.
- `qa.evidence_subpath` decoupled the QA path from any single repo
  layout.

The orchestrator code stays the same; you author four artifacts and
hand the host the credentials. That is "configurable per project,"
not "plug and play."
