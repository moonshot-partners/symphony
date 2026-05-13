# Symphony Elixir — VPS Deployment Runbook

This is a no-frills runbook for getting Symphony Elixir running on a Linux VPS so a
team can hand it Linear tickets and have an agent open PRs against a target repo.

> [!WARNING]
> Symphony Elixir is prototype software. There is no built-in HTTP dashboard, no
> auth in front of the agent, and no multi-tenant isolation. Run it on a host you
> control, with a dedicated Linear bot account and a dedicated GitHub identity.

## What you need

- A Linux VPS (any modern x86_64 distro with `git`, `curl`, `make`, `build-essential`).
- A Linear workspace where you can:
  - create a personal API key for a dedicated bot user, and
  - add the matching states (`Scheduled`, `In Development`, `In QA / Review`,
    `Released / Live`, `Closed`, `Canceled`, `Duplicate`) on the team that will
    receive Symphony work.
- A GitHub account or GitHub App that can push branches and open PRs against
  the target repository.
- An Anthropic credential — `ANTHROPIC_OAUTH_TOKEN` (claude.ai subscription, local
  use only per Anthropic ToS) or `ANTHROPIC_API_KEY` (paid API).

## 1. Install runtime dependencies

```bash
# mise — manages Elixir/Erlang versions per .mise.toml
curl https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc
exec bash

# uv — manages the Python agent shim virtualenv
curl -LsSf https://astral.sh/uv/install.sh | sh
```

## 2. Clone Symphony and install toolchains

```bash
git clone https://github.com/moonshot-partners/symphony /opt/symphony
cd /opt/symphony/elixir
mise trust
mise install                # installs Erlang 28 + Elixir 1.19 per .mise.toml
mise exec -- mix setup
mise exec -- mix build      # produces ./bin/symphony escript
```

## 3. Install the Python agent shim

The shim is a JSON-RPC bridge between Symphony's app-server protocol and
`claude-agent-sdk`.

```bash
cd /opt/symphony/elixir/priv/agent_shim
uv sync
# Capture the absolute path to the shim's Python interpreter; WORKFLOW.md
# references it as $SYMPHONY_AGENT_SHIM_PYTHON.
echo "SYMPHONY_AGENT_SHIM_PYTHON=$(pwd)/.venv/bin/python"
```

## 4. Configure environment variables

Symphony reads the following at startup. Put them in a systemd `EnvironmentFile`
(see step 6) — do not bake them into the unit file or commit them.

| Variable                            | Purpose                                                      |
|-------------------------------------|--------------------------------------------------------------|
| `LINEAR_API_KEY`                    | Linear personal API key for the bot user.                    |
| `LINEAR_ASSIGNEE`                   | Linear email of the user whose tickets Symphony picks up.    |
| `SYMPHONY_TARGET_REPO_URL`          | Git URL the `after_create` hook clones into each workspace.  |
| `SYMPHONY_AGENT_SHIM_PYTHON`        | Absolute path to the shim's `.venv/bin/python` from step 3.  |
| `ANTHROPIC_OAUTH_TOKEN` *or* `ANTHROPIC_API_KEY` | Auth for `claude-agent-sdk`.                    |
| `GH_TOKEN` *or* GitHub App vars     | Auth used by the agent to push branches and open PRs.        |

For GitHub App auth (recommended over PATs), set `SYMPHONY_GITHUB_APP_ID`,
`SYMPHONY_GITHUB_APP_INSTALLATION_ID`, and `SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH`.
The shim mints a fresh installation token automatically. See
[`docs/github-app-setup.md`](docs/github-app-setup.md) for the bootstrap CLI.

## 5. Configure WORKFLOW.md

Copy `elixir/WORKFLOW.md` to a location of your choice (for example
`/etc/symphony/WORKFLOW.md`) and customize:

- `tracker.project_slug` and/or `tracker.team_key` — pointing at the Linear
  team where Symphony should pick up work.
- `tracker.assignee` — leave as `$LINEAR_ASSIGNEE` to read from the env var.
- `tracker.api_key` — leave as `$LINEAR_API_KEY` to read from the env var.
- `workspace.root` — directory that will hold per-issue clones (must be
  writable by the Symphony service user).
- `agent.max_concurrent_agents` — start with `1` until you trust the setup.
- The Markdown body — adjust the prompt to your project's conventions.

If your Linear team uses different state names, update both the `active_states`
and `terminal_states` lists *and* the `## Status map` section in the prompt
body — they must stay aligned, or the agent will get confused about transitions.

## 6. systemd unit

Create `/etc/systemd/system/symphony.service`:

```ini
[Unit]
Description=Symphony Elixir agent orchestrator
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=symphony
Group=symphony
WorkingDirectory=/opt/symphony/elixir
EnvironmentFile=/etc/symphony/symphony.env
ExecStart=/usr/local/bin/mise exec -- /opt/symphony/elixir/bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root /var/log/symphony \
  /etc/symphony/WORKFLOW.md
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

Create the env file at `/etc/symphony/symphony.env` (chmod `600`, owner
`symphony:symphony`):

```bash
LINEAR_API_KEY=lin_api_...
LINEAR_ASSIGNEE=symphony-bot@yourcompany.com
SYMPHONY_TARGET_REPO_URL=git@github.com:your-org/your-repo.git
SYMPHONY_AGENT_SHIM_PYTHON=/opt/symphony/elixir/priv/agent_shim/.venv/bin/python
ANTHROPIC_OAUTH_TOKEN=...
GH_TOKEN=ghp_...
```

Provision and start:

```bash
sudo useradd -r -m -d /var/lib/symphony -s /usr/sbin/nologin symphony
sudo mkdir -p /var/log/symphony && sudo chown symphony:symphony /var/log/symphony
sudo chown -R symphony:symphony /opt/symphony
sudo systemctl daemon-reload
sudo systemctl enable --now symphony
sudo journalctl -u symphony -f
```

## 7. Verify

1. Watch `journalctl -u symphony -f` and confirm Symphony reports the
   Linear poll interval and a successful first poll.
2. Create a Linear issue assigned to `$LINEAR_ASSIGNEE` in an `active_states`
   state on the configured team.
3. Within `polling.interval_ms` you should see a workspace appear under
   `workspace.root`, the agent open a PR on `SYMPHONY_TARGET_REPO_URL`, and
   the issue progress through states defined in `## Status map`.

## Operational realities

- **No HTTP dashboard.** Observability is `journalctl -u symphony -f`,
  `./log/` (or `--logs-root`), and the per-issue agent comments the running
  agent posts back to its Linear ticket.
- **Single-host only.** No clustering, no shared state. Two Symphony processes
  pointing at the same Linear team will race each other.
- **Auth secrets live in the env file.** Rotate via the same `EnvironmentFile`
  + `systemctl restart symphony`. There is no in-process secret reload.
- **Workspace cleanup is hook-driven.** Symphony removes a workspace when the
  issue reaches a terminal state. Manual removal is safe when the service is
  stopped.
- **Restarts are cheap.** Symphony reloads `WORKFLOW.md` on signal and
  re-picks-up in-flight issues on startup. If a reload fails, Symphony keeps
  running with the last known-good config and logs the parse error.
