# Changelog

## Unreleased — GitHub App identity for orchestrator-driven PRs

### Highlights

- Symphony can now author PRs as the `symphony-orchestrator[bot]` GitHub App
  instead of the operator's personal account. The agent's git/gh subprocesses
  inherit a short-lived installation token (1h GitHub TTL, refreshed at 55min)
  via `GH_TOKEN` / `GITHUB_TOKEN`. Required when the operator wants to be the
  reviewer on agent-authored PRs (GitHub rejects self-review with HTTP 422).
- New shim module `symphony_agent_shim.auth_github_app` handles JWT signing
  (RS256, 9min TTL with backdated `iat` to absorb clock skew), installation
  token exchange, and a thread-safe in-memory token cache.
- New CLI `symphony-setup-github-app` walks the operator through the GitHub
  App manifest flow (one click to create) and writes credentials to
  `~/.symphony/github-app.{pem,env}` (pem chmod 600). Org install requires
  approval if the operator is not an owner — the CLI prints a copy-paste DM
  template for the org owner.
- New `agent_runtime.github_app_env` block in `WORKFLOW.*.md` declares the env
  vars passed through to the agent: `SYMPHONY_GITHUB_APP_ID`,
  `SYMPHONY_GITHUB_APP_INSTALLATION_ID`, `SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH`.

### Backwards compatibility

If any of the three `SYMPHONY_GITHUB_APP_*` vars is missing, the shim falls
back to the operator's `GH_TOKEN` / `GITHUB_TOKEN` (PAT) so existing runs keep
working. PAT mode does **not** set `SYMPHONY_GITHUB_APP_ACTIVE=1`, which lets
downstream tooling distinguish App-authored vs operator-authored runs.

### Manual install steps

1. `uv run symphony-setup-github-app --org <your-org>` — opens browser, creates
   the App, persists the pem and env file.
2. Click "Install" on the App page; pick "All repositories" on the org. If you
   are not an org owner, GitHub fires an approval request — DM an owner using
   the template the CLI prints.
3. After approval, finalize with
   `symphony-setup-github-app --finalize <installation_id>`.
4. `source ~/.symphony/github-app.env` before launching Symphony.

See `docs/github-app-setup.md` for the full runbook.

## Unreleased — Codex → Claude Agent SDK migration

### Highlights

- The default agent backend is now `python -m symphony_agent_shim`, a JSON-RPC stdio
  daemon that wraps `claude-agent-sdk`. The Codex `app-server` subprocess is no
  longer required for new installations.
- The shim ships in `priv/agent_shim/` with its own `pyproject.toml` (managed by
  `uv`). See `priv/agent_shim/README.md` for setup, smoke tests, and auth.

### Breaking changes

#### `workflow.yml` schema rename: `codex:` → `agent_runtime:`

The `codex:` block was renamed to `agent_runtime:` to reflect that the runtime
is no longer Codex-specific. **A backwards-compatible alias is in place for one
release** — workflows that still use `codex:` will load with a deprecation
warning. The alias will be removed in a future release.

```yaml
# Old (still accepted with a warning)
codex:
  command: codex app-server
  approval_policy: never

# New (recommended)
agent_runtime:
  command: python -m symphony_agent_shim
  approval_policy: never
```

If both `codex:` and `agent_runtime:` are set, `agent_runtime:` wins and the
`codex:` block is ignored (with a warning).

#### Default `agent_runtime.command`

The default for `agent_runtime.command` changed from `codex app-server` to
`python -m symphony_agent_shim`. To keep using Codex, override the command in
`workflow.yml`:

```yaml
agent_runtime:
  command: codex app-server
```

#### Module renames

Internal Elixir modules were renamed. **No backwards-compat aliases** — direct
references to the old names will not compile:

| Old                                | New                              |
| ---------------------------------- | -------------------------------- |
| `SymphonyElixir.Codex.AppServer`   | `SymphonyElixir.Agent.AppServer` |
| `SymphonyElixir.Codex.DynamicTool` | `SymphonyElixir.Agent.DynamicTool` |

Internal state fields named `codex_*` were renamed to `agent_*`/`last_agent_*`.
External callers shouldn't touch these — they are private.

#### `turn/completed.params.usage` field rename

When the agent backend is `symphony_agent_shim`, the `usage` field in
`turn/completed` now uses Anthropic field names instead of OpenAI's:

| Old (Codex)         | New (Claude SDK)                |
| ------------------- | ------------------------------- |
| `prompt_tokens`     | `input_tokens`                  |
| `completion_tokens` | `output_tokens`                 |
| (n/a)               | `cache_creation_input_tokens`   |
| (n/a)               | `cache_read_input_tokens`       |
| (n/a in events)     | `total_cost_usd` (top-level)    |

The dashboard reads these fields verbatim — no translation layer. Any
external consumer of these events must be updated.

### Other fixes bundled in this branch

- **Linear assignee filter**: when filtering issues by assignee, the GraphQL
  query now fetches `email`, `name`, and `displayName`, and the client-side
  matcher accepts a hit on any of the three. Required for assignees configured
  by email (e.g. `vinicius.freitas@moonshot.partners`).

### Migration steps

1. Rename `codex:` → `agent_runtime:` in your `workflow.yml`. The deprecation
   warning makes this discoverable on the next run.
2. Update any code that imports `SymphonyElixir.Codex.AppServer` or
   `SymphonyElixir.Codex.DynamicTool` to the `Agent.*` names.
3. Update dashboards/observability tooling that reads `usage.prompt_tokens` /
   `usage.completion_tokens` to use `input_tokens` / `output_tokens` (and
   surface the new `cache_*` and `total_cost_usd` fields).
4. Set up the Python shim:
   ```sh
   cd priv/agent_shim
   uv sync --extra dev
   ```
   Configure `ANTHROPIC_OAUTH_TOKEN` (preferred) or `ANTHROPIC_API_KEY` in the
   environment that runs Symphony.
