# Symphony — Consultant Deployment Guide

This guide is for the consultant who installs Symphony at a new client. It
distinguishes what the Symphony product provides out-of-the-box from what you,
the consultant, must configure for each project.

---

## Separation of concerns

| Layer | Owner | What it is |
|---|---|---|
| **Symphony product** | Symphony team | Orchestrator (Elixir), Docker base image, qa_helpers.py, agent shim |
| **Consultant setup** | Consultant | WORKFLOW.md, Linear project config, GitHub App, secrets, Docker build |
| **Project workflow** | Client + consultant | WORKFLOW rules, state names, repo conventions, issue quality standards |

Symphony product changes deploy to `/opt/symphony` on the VPS. WORKFLOW.md
edits live in the Symphony config repo and take effect on the next agent run —
no restart needed.

---

## Pre-flight checklist

### 1. Infrastructure

- [ ] VPS provisioned — run `ops/provision.sh` to reproduce the Symphony host from scratch
- [ ] Docker installed and daemon running (`docker ps` returns no error)
- [ ] Client base Docker image built successfully (e.g. `docker build -f docker/schoolsout-base/Dockerfile -t schoolsout-base:latest .`)
- [ ] Symphony Elixir app running under systemd (`systemctl status symphony`)

### 2. Secrets — confirm ALL are set in `/opt/symphony/.env` or systemd drop-in

- [ ] `LINEAR_API_KEY` — Linear personal API token with read/write on the client workspace
- [ ] `ANTHROPIC_API_KEY` — Claude API key (`sk-ant-oat01` prefix; no expiry concern)
- [ ] `GH_TOKEN` **or** GitHub App trio: `SYMPHONY_GITHUB_APP_ID`, `SYMPHONY_GITHUB_APP_INSTALLATION_ID`, `SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH`
- [ ] `CLAUDE_CODE_OAUTH_TOKEN` — for quality gate API calls inside the agent container

### 3. Linear workspace

- [ ] `team_key` in WORKFLOW.md matches the client's Linear team identifier (e.g. `SODEV`)
- [ ] State names in WORKFLOW.md match **exactly** what's in Linear (copy-paste, not type):
  - `active_states` — states the orchestrator polls for work
  - `on_pickup_state` — state set when agent picks up the ticket
  - `on_complete_state` — state set when PR is attached
  - `on_pr_merge_state` — state set when PR is merged — **never leave as `null`**; set to the client's "done/live" state name
- [ ] `routing_label` label exists in Linear; apply it to tickets you want Symphony to process
- [ ] Team understands the issue quality bar: clear ACs, no ambiguous scope, no "implement X however you want"

### 4. GitHub repositories

- [ ] GitHub App (or PAT) has write access to all repos the agent will push to
- [ ] Branch protection rules allow the bot identity to push feature branches
- [ ] Shallow clone fetch commands in `after_create` hook reference the correct integration branches (e.g. `dev`, not `main`)
- [ ] Integration branches exist on remote — shallow clones only fetch `main` by default; `after_create` must fetch the integration branch explicitly (e.g. `git fetch --depth=1 origin dev:refs/remotes/origin/dev`)

### 5. WORKFLOW.md

- [ ] `active_states` covers all states where the orchestrator should pick up work
- [ ] `on_pr_merge_state` is **not** `null` — set to the client's merged/live state name
- [ ] `workspace.root` exists and is writable on the VPS
- [ ] `agent.max_concurrent_agents` set to a value that fits Linear rate limits and server RAM
- [ ] `agent_runtime.read_timeout_ms` is at least `60000` — the default 5000ms kills the first agent turn
- [ ] `after_create` hook installs all deps required by the agent's quality gates (npm ci, bundle install, etc.)
- [ ] Repos listed in `after_create` match the actual GitHub org/repo slugs
- [ ] Gate A install check is present (e.g. `npx --no-install jest --listTests > /dev/null`) so broken workspaces fail loudly

### 6. Docker base image

- [ ] `qa_helpers.py` present in the image at `/opt/qa/qa_helpers.py` (mapped via `COPY docker/<client>-base/qa /opt/qa`)
- [ ] `PLAYWRIGHT_BROWSERS_PATH` set and Chromium installed in the image
- [ ] `npm ci` in `after_create` uses `--no-audit --no-fund` to avoid postinstall secrets failures
- [ ] Staging API CORS allowlist includes `localhost:3001` — the QA dev server runs on this port; any other port causes silent API failures

### 7. First-run validation

Create a synthetic test ticket with the `routing_label` in the first `active_state`:

- [ ] Orchestrator picks it up (check `journalctl -u symphony -f` or LiveDashboard)
- [ ] Agent posts first workpad comment — confirms Linear API key, workspace creation, and agent boot
- [ ] Agent opens a PR — confirms GitHub identity and branch push
- [ ] PR moves ticket to `on_complete_state` — confirms Linear state transition wiring
- [ ] QA evidence appears as Linear comment — confirms `qa_helpers` and `QaEvidence`
- [ ] Merge PR — confirm ticket advances to `on_pr_merge_state` (not stuck in review)

---

## Common failure modes

| Symptom | Root cause | Fix |
|---|---|---|
| Orchestrator never picks up ticket | `routing_label` missing on ticket, or state not in `active_states` | Add label; verify state name matches Linear exactly |
| Agent crashes `{:port_exit, 1}` immediately | Missing Python dep in shim venv | `uv pip install <pkg> --python priv/agent_shim/.venv/bin/python` |
| Agent silent on first turn (timeout) | `read_timeout_ms` too low (default 5000ms kills first turn) | Set `read_timeout_ms: 120000` in WORKFLOW |
| `npm test` fails with missing module | `npm ci` skipped or failed silently in `after_create` | Check hook output; add `set -euo pipefail` at top of hook |
| QA evidence not uploaded to Linear | `qa-evidence/` dir not created (agent skipped QA step or WORKFLOW rule 5 conditions not met) | Check WORKFLOW rule 5 trigger conditions; confirm diff touches UI files |
| Ticket stuck in "In QA / Review" after merge | `on_pr_merge_state: null` | Set to the client's merged/live state name |
| `session.webm` first 30s blank | TCP port open ≠ Next.js routes compiled | Ensure `qa_helpers.py` has `_http_ready()` (shipped in this PR); rebuild Docker image |
| Agent commits `qa_check.py` to PR diff | Old WORKFLOW rule 5d | Ensure WORKFLOW rule 5d says `state/<id>/qa_check.py` and not `fe-next-app/qa_check.py` |
| `gh pr create` fails with HTTP 422 | Agent identity is same as reviewer; GitHub rejects self-review | Add `# do not add --reviewer` note in WORKFLOW rule 6 |
| Workspace creation timed out | `timeout_ms` too low for `npm ci` + `bundle install` on cold network | Raise `timeout_ms` to 600000 (10 min) |

---

## Product vs project — what the consultant owns

The consultant sets up the **terrain** that Symphony operates on. Symphony product handles the rest automatically.

**Consultant owns (per client):**
- WORKFLOW.md configuration (state names, hooks, agent limits)
- Linear workspace setup (labels, state names, team access)
- GitHub App / PAT with correct repo permissions
- Docker base image customization (apt packages, QA locale, staging API URL)
- Secret injection into the VPS environment
- Issue quality standards (coaching the team to write clear ACs)
- Branch naming conventions documented in WORKFLOW.md

**Symphony product handles automatically:**
- Polling Linear for new tickets
- Workspace provisioning and teardown
- Agent dispatch and turn management
- Workpad comments (understanding, progress, final)
- QA evidence upload to Linear (screenshots, webm, report)
- Linear state transitions (pickup → complete → merged)
- PR label application
- Gate B (CI check validation)
- Gate C (AC extraction header validation)
