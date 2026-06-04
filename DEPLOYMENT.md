# Deployment — SchoolsOut Symphony

This is the **upstream openai/symphony** based deployment for SchoolsOut. It is
the live system. The old fork (gate-stack orchestrator) is retired.

## Which Symphony is this?

| | Legacy fork (retired) | This one (live) |
| --- | --- | --- |
| Local worktree | `~/Developer/symphony` (`main`, `deploy/*`) | `~/Developer/symphony-upstream-schoolsout` |
| Deploy branch | `main` | `schoolsout-prod` |
| Base | fork, diverged from openai/symphony | openai/symphony upstream + SchoolsOut config |
| Orchestrator | one file + ~40 gate modules (`orchestrator/gate_*.ex`, `plan_grounding_gate.ex`, `workpad_pr_sync.ex`) | one upstream file, **no gate modules** |
| Quick tell | has `lib/symphony_elixir/orchestrator/gate_*.ex` | has `tracker.label`, the `linear_graphql` tool, `board_state_names/1` |

Same git repo (`moonshot-partners/symphony`), different branches. `origin` is
the fork remote, `upstream` is `openai/symphony`.

## Canonical deploy branch

`schoolsout-prod` on `origin` is the single source of truth for what runs in
prod. Deploy from it; never deploy from a feature branch. Feature work branches
off `schoolsout-prod` and merges back via PR.

## How prod is deployed

The VPS (`/opt/symphony`) is a git checkout of `schoolsout-prod`. A deploy
pulls the branch, rebuilds the escript, restarts the systemd unit, and
health-checks. Gitignored runtime state (`elixir/_build`, `elixir/deps`,
`state/`, the dashboard build) survives untouched.

Deploy (current method, validated):

```
ssh "$SSH_USER@$SSH_HOST" 'bash -s' < scripts/deploy.sh
```

Deploy (CI, once enabled):

```
gh workflow run deploy.yml          # runs tests, then SSH-deploys via the same script
```

The `deploy.yml` workflow is committed but not yet triggerable: GitHub only
exposes `workflow_dispatch` for workflows on the repo default branch, which is
still `main` (the legacy fork). To enable CI deploys, make `schoolsout-prod`
the default branch (recommended, it also makes "what is current" unambiguous).
Until then, deploy with the manual command above.

What is running, from the VPS:

```
cat /opt/symphony/DEPLOYED_SHA              # the deployed git sha
git -C /opt/symphony rev-parse HEAD         # same, authoritative
```

## Runtime

- systemd unit `symphony`, runs as `ubuntu`, escript at
  `/opt/symphony/elixir/bin/symphony`, workflow at
  `/opt/symphony/elixir/WORKFLOW.schools-out.md`.
- Secrets live in `/etc/symphony/symphony.env` (not in git). Codex auth in
  `/home/ubuntu/.codex` (ChatGPT login, not an API key).
- HTTP API on loopback `:4010`: official `/api/v1/state`, `/api/v1/:issue`,
  `/api/v1/refresh`; cockpit extensions `/live`, `/board`.
- Cockpit (Next.js) on `:3000` behind Caddy basic auth; the Next BFF proxies to
  `:4010`. The cockpit build is separate from the escript deploy; rebuild it
  only when `dashboard/` changes.

## Health check

```
systemctl is-active symphony
curl -fsS http://127.0.0.1:4010/api/v1/state    # 200 = healthy
curl -fsS http://127.0.0.1:4010/board           # agent pipeline tickets
```

## Routing (how tickets reach the agent)

The tracker filters by the `agent` Linear label plus `active_states`
(`Scheduled`), not by project. Marianna (PM) labels a ticket `agent` and moves
it to `Scheduled`; the agent picks it up and drives its own Linear lifecycle
(`Scheduled -> In Development -> In Code Review`) via the `linear_graphql` tool.
Symphony only reads state; it never writes it.
