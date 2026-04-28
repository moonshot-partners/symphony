# symphony-agent-shim

JSON-RPC stdio shim translating Codex `app-server` protocol to
`claude-agent-sdk`. Symphony's `SymphonyElixir.Codex.AppServer` speaks
unchanged Codex JSON-RPC; this shim is the new daemon on the other side.

## Run standalone (smoke test)

```bash
cd priv/agent_shim
uv sync --extra dev
ANTHROPIC_OAUTH_TOKEN=$(cat ~/.config/claude-code/auth.json | jq -r .access_token) \
  uv run python -m symphony_agent_shim
```

## Symphony integration

`config.codex.command` (in `WORKFLOW.md`) is set to `python -m symphony_agent_shim`.
Symphony spawns the shim per session via `Port.open`.

## Auth

Precedence: `ANTHROPIC_OAUTH_TOKEN` > `ANTHROPIC_API_KEY`. OAuth token works
**locally only** — Anthropic ToS prohibits redistributing third-party apps
that use claude.ai subscription auth.

## Tests

```bash
uv run pytest -v
uv run ruff check . && uv run ruff format --check .
```
