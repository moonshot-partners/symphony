# `symphony-orchestrator` GitHub App — Setup Runbook

This runbook installs the `symphony-orchestrator` GitHub App so Symphony's
agent subprocess authors commits and PRs as `symphony-orchestrator[bot]`
instead of the operator's personal account. Without this, GitHub rejects the
agent's `gh pr create --reviewer <operator>` call with HTTP 422 (an account
cannot self-request review).

Total time on the happy path: ~5 minutes of operator work, plus async wait for
an org owner to approve the install.

## Prerequisites

- An installed shim: `cd priv/agent_shim && uv sync --extra dev`.
- A browser logged into the GitHub account that will **own** the App. We use
  the operator's personal account (`viniciuscffreitas`) so the operator does
  not need org-admin to create it.
- The org slug where the App will be installed (e.g. `schoolsoutapp`).
- The GitHub handle of an org owner who can approve the install. For
  `schoolsoutapp`, the owners are `barnaby67`, `elyse-so`, `rrodrigu3z`.

## Step 1 — Create the App (one click)

```bash
cd priv/agent_shim
uv run symphony-setup-github-app --org <your-org>
```

What happens:

1. The CLI builds a manifest declaring the App's name, callback URL, and
   least-privilege permissions: `contents:write`, `pull_requests:write`,
   `metadata:read`. No webhook events.
2. It opens an HTML page that auto-submits the manifest to GitHub. You are
   prompted once to confirm the App creation.
3. GitHub redirects to `http://127.0.0.1:8765/callback?code=...&state=...`.
   The CLI's local server captures the code, validates the `state` token
   (CSRF guard), and exchanges it via
   `POST /app-manifests/{code}/conversions`.
4. The CLI persists:
   - `~/.symphony/github-app.pem` — the App's private key, `chmod 600`.
   - `~/.symphony/github-app.env` — `SYMPHONY_GITHUB_APP_ID` and
     `SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH`. The
     `SYMPHONY_GITHUB_APP_INSTALLATION_ID` line is left commented until
     step 3.

If port 8765 is busy, pass `--port <free-port>`. To create the App on an org
where you **are** an owner instead of your personal account, the `--org` flag
already targets the org's manifest endpoint.

## Step 2 — Install the App on the org

The CLI prints the App's HTML URL. Open `<app-url>/installations/new` and
choose **All repositories** for the target org.

If you are an org owner: install completes immediately, GitHub redirects to
the install page with `installation_id=<n>` in the query string. Note that
number — you need it in step 3.

If you are **not** an org owner: GitHub shows "Request sent" and emails the
owners. The CLI prints a copy-paste DM template like:

```
Hey @<owner> — quick ask: I just created the symphony-orchestrator GitHub
App on my personal account so the Symphony agent can author PRs as a bot
instead of me. It needs org-level install on <org> (All repositories) with
contents:write, pull_requests:write, metadata:read.

App: <app-url>

Could you approve the install request when you get a sec? Thanks!
```

DM the owner. After they click Approve, the install lands silently — there's
no notification. Discover the `installation_id` either by:

- Refreshing `<app-url>/installations` while logged in as the App owner — the
  org appears with an "Configure" link whose URL is `.../installations/<id>`.
- Or run `symphony-setup-github-app --discover-install <org>` (uses an App
  JWT to query `GET /orgs/<org>/installation`). _(Note: the discovery flag
  is not yet wired into the CLI; for now the
  `discover_installation_id()` function in
  `symphony_agent_shim.auth_github_app` is callable from a Python REPL.)_

## Step 3 — Finalize the env file

```bash
uv run symphony-setup-github-app --finalize <installation_id>
```

This patches `~/.symphony/github-app.env` to set
`SYMPHONY_GITHUB_APP_INSTALLATION_ID=<n>` (replacing the commented placeholder
with no duplicates).

## Step 4 — Source the env and relaunch Symphony

```bash
source ~/.symphony/github-app.env
./bin/symphony ./WORKFLOW.schools-out.md
```

The shim's `resolve_git_env()` reads the three env vars on every thread start,
mints a fresh installation token (cached in-process for 55 minutes), and
injects `GH_TOKEN` / `GITHUB_TOKEN` / `SYMPHONY_GITHUB_APP_ACTIVE=1` into the
agent subprocess. The agent's `git push` and `gh pr create` calls now run as
the App.

To confirm: pick up a sandbox ticket and watch the resulting PR — author
should be `symphony-orchestrator[bot]`, and `--reviewer <operator>` should
succeed.

## Troubleshooting

**`error: port 8765 is busy; pass --port`** — another process holds the
loopback port. Pass `--port 8766` (or any free port) to the CLI.

**`GitHub HTTP 401: Bad credentials`** when minting the installation token —
the `installation_id` in the env file does not match an active installation
of this App. Re-run step 3 with the correct id, or revoke and reinstall.

**PR is still authored by the operator** — `SYMPHONY_GITHUB_APP_ACTIVE` is
not set in the agent's env. Either the env file was not sourced, or one of
the three `SYMPHONY_GITHUB_APP_*` vars is missing. The shim falls back to PAT
silently in that case. Check with:

```bash
env | grep SYMPHONY_GITHUB_APP
```

**Org install was revoked by an owner** — installation tokens stop minting.
Re-run step 2 to request approval again; the App and private key remain
valid, only the installation needs re-approval.

**Permission errors on the pem** — the file must be `chmod 600`. The CLI sets
this on creation; if you copied the file, re-apply with
`chmod 600 ~/.symphony/github-app.pem`.

## Security notes

- The private key is the only long-lived secret. Treat
  `~/.symphony/github-app.pem` like an SSH key: never commit it, never share
  it. If exposed, rotate via the App's settings page (Generate a new private
  key, then delete the old one).
- The shim never logs the JWT or the installation token. Token TTL is 1 hour
  and the cache holds it for at most 55 minutes.
- Permissions are least-privilege: the App can read repo metadata, push to
  branches, and create/comment on PRs. It cannot read code outside the
  installed repos, write to repository settings, or access org members.
