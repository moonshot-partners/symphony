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

## Tracing (optional, Langfuse)

When `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY` are present in the shim
process environment, `symphony_agent_shim.tracing` instruments each turn with
the OpenInference OpenTelemetry instrumentor and exports a span tree per turn to
Langfuse (per-API-call generations, tool calls, token usage, model, latency).
Each Linear ticket maps to one Langfuse Session via `session_id = ticket`
(`SODEV-430`, etc.); the per-process shim thread id is recorded as metadata.

Symphony also emits explicit operational observations around the raw SDK trace:

- `symphony.turn`
- `symphony.turn.query`
- `symphony.turn.stream`
- `symphony.tool.bash`
- `symphony.tool.file_change`

These spans add searchable names and short metadata for the actions operators
actually debug: turn id, thread id, ticket, command category, cwd, and file path.
Raw prompt/output capture defaults to redacted summaries. Set
`LANGFUSE_CAPTURE_IO=full` only for a bounded debugging session; use
`LANGFUSE_CAPTURE_IO=off` to suppress input/output payloads entirely.

Absent the keys, tracing is a no-op — no setup needed for local runs or tests.
A tracing failure never propagates into the agent loop.

Required env:

```bash
LANGFUSE_PUBLIC_KEY=<langfuse-public-key>
LANGFUSE_SECRET_KEY=<langfuse-secret-key>
LANGFUSE_HOST=https://cloud.langfuse.com      # EU cloud; US is https://us.cloud.langfuse.com
LANGFUSE_BASE_URL=https://cloud.langfuse.com  # set both — SDK versions read either
LANGFUSE_TRACING_ENVIRONMENT=production
LANGFUSE_CAPTURE_IO=redacted
OTEL_SERVICE_NAME=symphony-agent-shim
```

How the keys reach the shim:

- **bash mode** (default, e.g. Hetzner): the shim inherits the Symphony
  orchestrator process env, so set `LANGFUSE_*` in the systemd unit (or shell)
  that launches Symphony.
- **docker mode**: the container does not inherit host env. `LANGFUSE_*` are in
  the `@docker_passthrough_env` allowlist in
  `lib/symphony_elixir/agent/app_server/transport.ex`, forwarded via `docker run -e`.

Never commit the keys. They live in the process env / secret store only.

## Tests

```bash
uv run pytest -v
uv run ruff check . && uv run ruff format --check .
```
