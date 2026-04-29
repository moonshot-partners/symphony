# Changelog

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
