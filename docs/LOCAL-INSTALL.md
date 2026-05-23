# Running Symphony locally

This is the install guide for an engineer who wants a Symphony instance
running on their own machine — laptop or workstation, not the Hetzner
VPS that drives schools-out work. The goal is a safe sandbox in which
to experiment, file bugs, and contribute, without any chance of
touching production tickets.

> [!IMPORTANT]
> **A local Symphony cannot share a Linear team with production.**
> Symphony polls Linear by `tracker.team_key`, picks up any ticket in
> the configured active states, and drives it to a PR. If your local
> install points at the production team (`SODEV`, `SYM`), it will race
> the Hetzner instance for the same tickets. Step 4 below is the only
> safe path.

If you want to wire Symphony to a **new project** (not just run it
locally), read [`docs/ONBOARDING.md`](./ONBOARDING.md) instead. That
covers the per-project artifacts (base image, `WORKFLOW.<project>.md`,
per-repo `AGENTS.md`).

## Prerequisites

A laptop or workstation with:

- A working shell (`bash` or `zsh`).
- [`git`](https://git-scm.com/) and `curl`.
- [Docker](https://docs.docker.com/desktop/) — the agent runs in a
  container per ticket. Docker Desktop on macOS works; Colima also
  works. Test with `docker run hello-world` before continuing.
- [`mise`](https://mise.jdx.dev/) — manages Erlang and Elixir versions
  per `elixir/mise.toml`. Don't install Erlang/Elixir manually; the
  pinned versions in `mise.toml` are the only combination tested.
- [`uv`](https://docs.astral.sh/uv/) — manages the Python virtualenv
  the agent shim runs in.

On macOS, install with Homebrew + the official scripts:

```
brew install git curl
curl https://mise.run | sh                  # follow the printed shellrc update
curl -LsSf https://astral.sh/uv/install.sh | sh
```

## 1. Clone and install toolchains

Symphony lives in `~/Developer/symphony` by convention. The Elixir
project root is the `elixir/` subdirectory — `mix.exs` is there, **not**
at the repo root. If you `cd` into the wrong directory, `mix` will say
"could not find a Mix.Project" or similar; that is the most common
"I think mise is broken" misdiagnosis on this codebase.

```
git clone https://github.com/moonshot-partners/symphony ~/Developer/symphony
cd ~/Developer/symphony/elixir
mise trust
mise install                # installs Erlang 28 + Elixir 1.19 per mise.toml
mise exec -- mix setup
mise exec -- mix build      # produces ./bin/symphony escript
```

### Known gotcha — `erl` not on macOS PATH after `mise install`

`mise install` puts Erlang under `~/.local/share/mise/installs/erlang/<ver>/bin`,
not on `PATH`. Most Symphony commands work via `mise exec --`, but
some shim subprocesses spawned by the orchestrator at runtime invoke
`erl` directly and need it on `PATH`. The known workaround is to
export the Homebrew Erlang directory on macOS as a fallback:

```
echo 'export PATH="/opt/homebrew/opt/erlang/bin:$PATH"' >> ~/.zshrc
exec zsh
```

If you don't have Homebrew Erlang installed, run
`brew install erlang` first. The Homebrew Erlang and the mise-pinned
Erlang are both Erlang 27+; the shim only invokes `erl --version`-style
calls, so the slight version drift is harmless.

## 2. Install the Python agent shim

The shim bridges Symphony's app-server protocol to `claude-agent-sdk`.
It lives in `elixir/priv/agent_shim/` and runs in its own venv.

```
cd ~/Developer/symphony/elixir/priv/agent_shim
uv sync
echo "SYMPHONY_AGENT_SHIM_PYTHON=$(pwd)/.venv/bin/python"
```

Copy the printed line — you'll paste it into the env file in step 5.

### Known gotcha — shim venv missing transitive deps

If the agent crashes at boot with `{:port_exit, 1}` and the log shows
`ModuleNotFoundError: No module named '<package>'`, the shim venv is
missing a transitive dependency. Fix:

```
cd ~/Developer/symphony/elixir/priv/agent_shim
uv pip install <package_name> --python .venv/bin/python
```

`uv sync` is supposed to handle this, but historically `pyyaml` and a
couple of others have slipped through on first install.

## 3. Credentials

You need three sets of credentials — none of them production:

1. **A personal Linear API key.** Linear → Settings → Security &
   access → Personal API keys. Mint a key under your own user, **not**
   under a shared bot account. Locally-scoped key = locally-blast-radius.
2. **An Anthropic credential.** Either
   `ANTHROPIC_OAUTH_TOKEN` (claude.ai subscription — local use only per
   Anthropic ToS; do not use on shared infra) or `ANTHROPIC_API_KEY`
   (paid API). The OAuth path is easier for local experimentation.
3. **A GitHub credential.** Either a personal access token
   (`GH_TOKEN`) scoped to whatever throwaway repo you'll target in
   step 4, or the GitHub App vars
   (`SYMPHONY_GITHUB_APP_*`) if you've already configured the App.
   For local: `GH_TOKEN` is the path of least resistance.

Symphony's launch helper (`source ~/.symphony/launch.sh`) pulls these
from the macOS keychain on Vinicius's machine; on a new machine, just
export them in your shell or put them in the env file (step 5).

## 4. Set up a sandbox Linear team and throwaway repo

This is **the safety step.** A local Symphony instance must point at
a sandbox Linear team it owns and a throwaway GitHub repo. Skipping
this is how you end up racing the production Hetzner instance for the
same SODEV tickets.

### A. Sandbox Linear team

In Linear:

1. Create a new team under your workspace. Name it something like
   `<YOUR-INITIALS>-SANDBOX` (e.g. `RM-SANDBOX`). The team identifier
   becomes your `tracker.team_key` in step 5.
2. Add the workflow states Symphony transitions between. The minimal
   set for the template workflow:
   - `Scheduled` (first active state — dispatch entry point)
   - `In Development` (pickup state)
   - `In Code Review` (complete + exhaust state)
   - `Ready for QA` (PR-merge state)
   - `On Hold / Blocked` (reject state)
   - At least one terminal state (`Closed` or `Done`).
3. Create a label called `agent` on the team — that is the routing
   label Symphony picks up by.

The sandbox team **must not be the same team production runs on.**
Production is `SODEV` (schools-out) and `SYM` (Symphony itself); both
are off-limits for local.

### B. Throwaway GitHub repo

Either fork the upstream repo you want to play with (`schoolsoutapp/schools-out`
→ `<your-username>/schools-out-sandbox`), or create an empty repo of
your own with a Dockerfile + README + minimal codebase. Point
`SYMPHONY_TARGET_REPO_URL` at the SSH URL of **that** repo, not the
upstream — otherwise the agent will try to open PRs against the real
project, which will reject the push.

## 5. Configure a local workflow file

Copy [`docs/templates/WORKFLOW.template.md`](./templates/WORKFLOW.template.md)
to a location of your choice — `~/.symphony/WORKFLOW.local.md` is the
suggested path. Fill in:

- `tracker.team_key: <YOUR-INITIALS>-SANDBOX` (the team from step 4A).
- `workspace.root: ~/code/symphony-local-workspaces`.
- `repos[]`:
  - `url:` — the throwaway repo SSH URL from step 4B.
  - `branch:` — whatever default branch that repo uses (`main` if it's
    a fresh fork).
  - `install:` — start with an empty `:` no-op and add tools as you
    discover them.
- `agent_runtime.docker_image:` — start with a stock image like
  `ubuntu:24.04`. Build a project-specific base image only when you
  start running tickets that need a real toolchain (see
  [`docs/ONBOARDING.md`](./ONBOARDING.md) step 1).
- `agent.max_concurrent_agents: 1` — keep concurrency at 1 locally so
  you can read the logs.

Then export the env vars or put them in a file the launch script can
source:

```
# ~/.symphony/local.env  (chmod 600)
LINEAR_API_KEY=lin_api_...
LINEAR_ASSIGNEE=<your-linear-email>
SYMPHONY_TARGET_REPO_URL=git@github.com:<you>/<sandbox-repo>.git
SYMPHONY_AGENT_SHIM_PYTHON=/Users/<you>/Developer/symphony/elixir/priv/agent_shim/.venv/bin/python
ANTHROPIC_OAUTH_TOKEN=sk-ant-oat01-...
GH_TOKEN=ghp_...
SYMPHONY_WORKFLOW_FILE=/Users/<you>/.symphony/WORKFLOW.local.md
```

## 6. Boot Symphony

```
cd ~/Developer/symphony/elixir
set -a; source ~/.symphony/local.env; set +a
mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails $SYMPHONY_WORKFLOW_FILE
```

The `--i-understand-that-this-will-be-running-without-the-usual-guardrails`
flag is mandatory; Symphony refuses to start without it. That is the
intended UX — running an autonomous agent on your machine is a
deliberate act.

If the boot succeeds you should see logs along the lines of
`polling Linear team <YOUR-INITIALS>-SANDBOX every 5s`.

## 7. Smoke-dispatch a ticket

In Linear, on your sandbox team:

1. Create a ticket with a clear, testable acceptance criterion (read
   [`TICKET-PLAYBOOK.md`](../TICKET-PLAYBOOK.md) "What makes a good
   ticket" for the rubric).
2. Apply the `agent` label.
3. Move it into `Scheduled`.

Within `polling.interval_ms`, you should see:

- A workspace appear under `workspace.root`.
- Symphony move the ticket to `In Development`.
- The agent post `## AC Extracted` as a Linear comment on the ticket.
- Eventually a PR open on your throwaway GitHub repo.

If any step hangs or fails, watch the logs (`journalctl` if you
daemonized; stdout if you ran in the foreground) and the Linear
workpad. The agent's last message on the workpad is your best
diagnostic.

## Operational notes

- **Stop with Ctrl-C.** Symphony cleans up active workspaces on
  graceful shutdown; a hard kill (Ctrl-\, SIGKILL) leaves them under
  `workspace.root` until the next boot's reconciliation pass.
- **Resetting state.** Stop Symphony, `rm -rf` the workspace root, and
  delete the test tickets in Linear. No other state survives between
  runs.
- **Reading logs.** `tail -F log/symphony.log` is the friendlier view.
  `--logs-root /path/to/dir` redirects everywhere except stdout.
- **One Symphony per workstation.** Two instances racing the same
  team_key is undefined behavior. If you need multi-tenant
  experimentation locally, use multiple sandbox teams plus multiple
  workflow files, one process each, but seriously: don't.

## Common boot failures

- **`Could not find a Mix.Project`** — you `cd`-d into the repo root,
  not the `elixir/` subdir.
- **`{:port_exit, 1}` at agent spawn** — shim venv missing a Python
  dep; see step 2 gotcha.
- **`HTTP 401 from Linear`** — `LINEAR_API_KEY` is missing or
  expired. Re-mint and re-source the env file.
- **`Permission denied` on workspace.root** — the `mkdir -p` succeeds
  but `File.rm_rf!` fails because something else (Docker bind-mount
  with `-u root`) wrote root-owned files there. Stop everything,
  `sudo rm -rf <workspace.root>`, fix your Docker image to use a
  matching UID (Step 1 of `docs/ONBOARDING.md`).
- **`could not find a default branch`** — your throwaway repo is
  empty. Add an initial commit (`git commit --allow-empty`) and push
  the default branch before re-dispatching.

## What's out of scope here

- One-click installer — not in this guide; this is the documented
  manual path. Automating it is a separate effort.
- New-project wiring (Docker image authoring, per-repo `AGENTS.md`) —
  see [`docs/ONBOARDING.md`](./ONBOARDING.md).
- Long-running deployment on a server — see
  [`elixir/DEPLOYMENT.md`](../elixir/DEPLOYMENT.md) for the VPS
  runbook.
