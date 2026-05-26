# Memoria MCP Tool — Operator Runbook

Optional Memoria integration that exposes the `search_knowledge` MCP tool to
the agent for decision-level human context (Slack threads, meeting notes, wiki
pages). Opt-in per client via `WORKFLOW.<client>.md`. Fail-open: if the API key
is missing or Memoria returns 5xx, the tool returns an empty result and the
agent proceeds without it.

**Not for code lookup.** File and symbol searches belong in `grep`/`glob`/
`find`. Memoria indexes Slack, Drive, and wiki; it is not repo-aware.

## When to enable

Enable for clients where the agent benefits from product/people/decision
context that lives outside the repo. Schools Out is the canonical case (325
wiki pages, year of Slack history). For greenfield repos with no Memoria
project, leave the `memoria:` block out — there is no fallback to enable.

## Prerequisites

- A Memoria project provisioned by Pedro Tavares with a UUID and a tag slug.
  Ask in `#memoria` Slack channel.
- The Symphony service-account token (format `mem_<64-hex>`) issued for that
  project. One token per Symphony deployment; no per-client tokens.

## Step 1 — Provision the API key

The key never lives in source. Two surfaces hold it:

1. **GitHub Actions secret** (for CI runs of the shim's pytest suite, if
   any test ever hits the live API — today the suite uses respx mocks, so this
   is forward-looking):

   ```bash
   gh secret set MEMORIA_API_KEY --repo moonshot-partners/symphony
   ```

2. **Hetzner production env** at `/etc/symphony/symphony.env` on `46.62.226.192`:

   ```bash
   ssh -i ~/.ssh/symphony_ci_hetzner root@46.62.226.192 \
     "echo 'MEMORIA_API_KEY=mem_<64-hex>' >> /etc/symphony/symphony.env && \
      systemctl restart symphony"
   ```

   Verify the var reaches the orchestrator:

   ```bash
   ssh -i ~/.ssh/symphony_ci_hetzner root@46.62.226.192 \
     'systemctl show symphony --property=Environment | grep -c MEMORIA_API_KEY'
   ```

   Expected: `1`.

## Step 2 — Opt the client into the tool

In the client's `WORKFLOW.<client>.md`, under `agent_runtime:`, add:

```yaml
agent_runtime:
  # ...other fields...
  memoria:
    project_id: <memoria-project-uuid>
    project_tag: <client-tag-slug>
```

`project_id` is the Memoria UUID. `project_tag` is the client-side tag filter
applied to every result; sources that lack the tag (and lack the cross-cutting
`moonshot` tag) are dropped before the agent sees them. This guards against
cross-tenant leakage from shared Slack workspaces.

Schools Out reference:
```yaml
memoria:
  project_id: 574d7d43-82b9-44ac-b2c2-a8dc93e84c8e
  project_tag: schools-out
```

If the block is absent, the shim does not load the tool. If only one field is
set, the orchestrator emits neither `MEMORIA_PROJECT_ID` nor `MEMORIA_PROJECT_TAG`
to the shim — all-or-nothing, no half-injection.

## Step 3 — Verify locally before pushing

```bash
cd elixir
export PATH=/opt/homebrew/opt/erlang/bin:$PATH
mix test test/symphony_elixir/workspace_and_config_test.exs \
         test/symphony_elixir/agent/transport_guardrail_env_test.exs \
         test/symphony_elixir/agent/turn_memoria_call_test.exs
```

All three suites must pass: workflow parsing, env injection, and decision log
routing.

## Step 4 — Observe the tool in action

After the next agent run touches a Memoria-tagged ticket, check the decision
log for `memoria.call` events:

```bash
ssh -i ~/.ssh/symphony_ci_hetzner root@46.62.226.192 \
  'grep memoria.call /opt/symphony/state/decisions.jsonl | tail -5'
```

Each entry contains:
- `tool` — always `search_knowledge` today.
- `query` — the agent's natural-language query.
- `result_status` — `ok`, `no_results`, or `error`.
- `source_ids` — the Memoria source IDs returned.
- `filtered_count` — how many sources survived the client-side tag filter.

If `result_status=error` appears in every call, check `MEMORIA_API_KEY` on
Hetzner and confirm Memoria is up: `curl https://memoria.moonshot-apps.com/api/v1/projects/<uuid> -H "Authorization: Bearer $MEMORIA_API_KEY"`.

## Failure modes

- **HTTP 503 from Memoria**: documented ~50% rate at one point. The client
  retries once with 250 ms backoff and returns empty on the second failure.
  The agent never blocks on Memoria.
- **HTTP 4xx**: hard failure, no retry, empty result. Usually a malformed
  query or expired token.
- **Cross-tenant leak in `project=` filter**: Memoria's server-side filter is
  not airtight in shared Slack workspaces (multiple Moonshot projects share
  `T33D257PC`). The client-side tag filter is the only airtight scope; never
  remove it.
- **Source freshness**: Memoria captures snapshots. Sources older than 180 d
  are annotated `AGED, cross-check`; older than 365 d are `STALE, verify
  against code`. The agent surfaces these annotations in its responses.

## Rotating the API key

1. Ask Pedro for a new token.
2. Update the GitHub Actions secret: `gh secret set MEMORIA_API_KEY --repo moonshot-partners/symphony`.
3. Update `/etc/symphony/symphony.env` on Hetzner and `systemctl restart symphony`.
4. Confirm a fresh `memoria.call` entry in `decisions.jsonl` after the next run.

There is no overlap window. The token is single-use; the swap takes effect at
restart.
