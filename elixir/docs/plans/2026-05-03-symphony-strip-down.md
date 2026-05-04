# Symphony Strip-Down Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut Symphony from ~9.5k LOC (lib/ + priv/) to ~3k LOC core by deleting unused machinery (multi-host SSH, TUI dashboard, Phoenix web, specs_check) while preserving the proven loop and the Sprint 3 deferred-shutdown handshake.

**Architecture:** Deletion order is dependency-driven — refactor callers to drop the dependency BEFORE deleting the dependency. Three phases: (1) caller-refactors strip multi-host & StatusDashboard from orchestrator/agent_runner/workspace/codex_app_server, (2) bulk-delete now-unreachable modules (status_dashboard.ex, ssh.ex, specs_check, entire `lib/symphony_elixir_web/` tree, `http_server.ex`), (3) split orchestrator.ex into focused files (`reconcile.ex`, `pr_shutdown.ex`, `workpad_sync.ex`, `agent_lifecycle.ex`).

**Tech Stack:** Elixir/OTP, ExUnit, Ecto changesets (config), Phoenix (being deleted), claude-agent-sdk Python shim (kept).

---

## Decisions locked in (Karpathy guardrails)

- **Tracker behaviour stays.** `tracker.ex` (46 LOC) + `tracker/memory.ex` (72 LOC) are real test seam — Memory adapter prevents network in unit tests. Deleting the behaviour saves no real LOC and breaks the test isolation primitive. Original spec asked to delete this; reversed after recon.
- **`stall_timeout_ms`** stays as config field (still useful locally for hung-shim detection), but stall-handler code that targets remote hosts (if any) is removed.
- **Multi-agent local concurrency PRESERVED.** Only multi-HOST is deleted. After strip, `max_concurrent_agents: 3` must still parallelise 3 issues on the same BEAM.
- **Shim sandbox NOT touched.** `bypassPermissions` stays. Out of scope.

## Pre-flight check (already done by planner)

- Branch `feature/symphony-strip-down` created off `main`.
- LOC inventory captured.
- Dep graph for top-LOC files captured.

---

## Task 1: Delete specs_check (no callers in production code path)

**Files:**
- Delete: `lib/symphony_elixir/specs_check.ex` (175 LOC)
- Delete: `lib/mix/tasks/specs.check.ex` (53 LOC)
- Delete: `test/symphony_elixir/specs_check_test.exs` (92 LOC)
- Delete: `test/mix/tasks/specs_check_task_test.exs` (112 LOC)

- [ ] **Step 1: Verify no production code imports SpecsCheck**

```bash
cd /Users/vini/Developer/symphony/elixir
grep -rn "SpecsCheck\|specs_check\|Mix.Tasks.Specs" lib/ --include="*.ex" | grep -v "lib/symphony_elixir/specs_check.ex" | grep -v "lib/mix/tasks/specs.check.ex"
```

Expected output: empty.

- [ ] **Step 2: Delete the four files**

```bash
rm lib/symphony_elixir/specs_check.ex lib/mix/tasks/specs.check.ex test/symphony_elixir/specs_check_test.exs test/mix/tasks/specs_check_task_test.exs
```

- [ ] **Step 3: Compile + run remaining test suite to confirm no fallout**

```bash
mix compile --warnings-as-errors 2>&1 | tail -10
mix test 2>&1 | tail -10
```

Expected: compile clean, tests pass (specs_check tests gone; nothing else referenced them).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore(strip): delete specs_check (unused, no callers)"
git push -u origin feature/symphony-strip-down
```

---

## Task 2: Strip multi-host from `agent_runner.ex`

**Files:**
- Modify: `lib/symphony_elixir/agent_runner.ex` (203 LOC → ~120 LOC)

- [ ] **Step 1: Snapshot current behaviour with targeted test run**

```bash
mix test test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/core_test.exs 2>&1 | tail -5
```

Expected: all pass (baseline before edit).

- [ ] **Step 2: Edit `agent_runner.ex` — remove `selected_worker_host`, `worker_host` parameter threading, `worker_host_for_log`. All callsites become local-only.**

Replace this block (lines 9-22 region):

```elixir
@type worker_host :: String.t() | nil

@spec start_run(map(), pid(), keyword()) :: {:ok, pid()} | {:error, term()}
def start_run(issue, codex_update_recipient, opts \\ []) do
  worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

  Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

  case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
```

With:

```elixir
@spec start_run(map(), pid(), keyword()) :: {:ok, pid()} | {:error, term()}
def start_run(issue, codex_update_recipient, opts \\ []) do
  Logger.info("Starting agent run for #{issue_context(issue)}")

  case run_locally(issue, codex_update_recipient, opts) do
```

Then rename `run_on_worker_host` → `run_locally`, drop the `worker_host` parameter from it and from every helper it calls (`send_worker_runtime_info`, `run_codex_turns`). Drop `selected_worker_host/2` and `worker_host_for_log/1`. Replace all `worker_host:` keyword passes downstream with literal `nil` (or just stop passing).

Concretely the helpers become:

```elixir
defp run_locally(issue, codex_update_recipient, opts) do
  Logger.info("Starting worker attempt for #{issue_context(issue)}")

  case Workspace.create_for_issue(issue) do
    {:ok, workspace} ->
      send_runtime_info(codex_update_recipient, issue, workspace)

      try do
        with :ok <- Workspace.run_before_run_hook(workspace, issue) do
          run_codex_turns(workspace, issue, codex_update_recipient, opts)
        end
      after
        Workspace.run_after_run_hook(workspace, issue)
      end

    {:error, reason} ->
      {:error, reason}
  end
end

defp send_runtime_info(recipient, %Issue{id: issue_id}, workspace) when is_pid(recipient) do
  send(recipient, {
    :agent_runtime_info,
    issue_id,
    %{worker_host: nil, workspace_path: workspace}
  })

  :ok
end

defp send_runtime_info(_recipient, _issue, _workspace), do: :ok

defp run_codex_turns(workspace, issue, codex_update_recipient, opts) do
  with {:ok, session} <- AppServer.start_session(workspace) do
    # ... rest of existing run_codex_turns body, with worker_host references removed
  end
end
```

(Keep `worker_host: nil` in `send_runtime_info` payload — orchestrator and workpad still display "Worker host: local" from this field, see `workpad.ex:181`.)

- [ ] **Step 3: Verify compile + targeted tests still pass**

```bash
mix compile --warnings-as-errors 2>&1 | tail -10
mix test test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/app_server_test.exs 2>&1 | tail -5
```

Expected: clean compile, all targeted tests green.

- [ ] **Step 4: Commit**

```bash
git add lib/symphony_elixir/agent_runner.ex
git commit -m "refactor(agent_runner): strip multi-host worker selection (local-only)"
git push
```

---

## Task 3: Strip SSH from `codex/app_server.ex`

**Files:**
- Modify: `lib/symphony_elixir/codex/app_server.ex` (1096 LOC → ~950 LOC)

- [ ] **Step 1: Edit alias line at top to drop `SSH`**

Change line 7 from:

```elixir
alias SymphonyElixir.{Codex.DynamicTool, Config, PathSafety, SSH}
```

To:

```elixir
alias SymphonyElixir.{Codex.DynamicTool, Config, PathSafety}
```

- [ ] **Step 2: Drop the `worker_host` parameter from `start_session/2` public API and all internal threads**

Find every function head matching `defp xxx(workspace, worker_host) when is_binary(worker_host) do` and delete it (the SSH-only branch). Keep the local branch (function head matching `worker_host` nil/missing).

Functions to surgically remove the remote branch from (verified via grep):
- `validate_workspace_cwd/2` (line 175 area, remote branch handles `:empty_remote_workspace`/`:invalid_remote_workspace`)
- `start_port/2` (line 212 area, remote branch calls `SSH.start_port`)
- `port_metadata/2` (line 225 area, remote branch puts `worker_host` in metadata — replace with always-local metadata)
- `session_policies/2` (line 269 area, remote branch SSH-fetches policies — keep local-only)

For each: keep the head pattern that handles local case, delete the SSH head, drop the `worker_host` parameter. Then update call sites in `start_session/2` to stop passing `worker_host`.

`start_session/2` becomes:

```elixir
def start_session(workspace, opts \\ []) when is_binary(workspace) do
  with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace),
       {:ok, port} <- start_port(expanded_workspace) do
    metadata = port_metadata(port)

    with {:ok, session_policies} <- session_policies(expanded_workspace) do
      {:ok,
       %__MODULE__{
         port: port,
         workspace: expanded_workspace,
         metadata: metadata,
         policies: session_policies
       }}
    end
  end
end
```

(Drop `worker_host: worker_host` from the struct line; drop `Keyword.get(opts, :worker_host)` line above.)

- [ ] **Step 3: Update the `t()` typespec to remove `worker_host` field**

Change the `@type t :: %__MODULE__{...}` block to drop `worker_host: String.t() | nil`. Verify struct definition (look for `defstruct`) similarly drops `:worker_host`.

- [ ] **Step 4: Compile + run app_server tests**

```bash
mix compile --warnings-as-errors 2>&1 | tail -10
mix test test/symphony_elixir/app_server_test.exs 2>&1 | tail -5
```

Expected: clean. If app_server_test references `worker_host` in test setup, those tests need updating in this same task — find them via `grep -n "worker_host" test/symphony_elixir/app_server_test.exs` and remove the field from struct construction / assertions.

- [ ] **Step 5: Commit**

```bash
git add lib/symphony_elixir/codex/app_server.ex test/symphony_elixir/app_server_test.exs
git commit -m "refactor(app_server): strip SSH branches (local Port only)"
git push
```

---

## Task 4: Strip SSH from `workspace.ex`

**Files:**
- Modify: `lib/symphony_elixir/workspace.ex` (483 LOC → ~280 LOC)

- [ ] **Step 1: Edit alias to drop `SSH`**

Line 7:

```elixir
alias SymphonyElixir.{Config, PathSafety, SSH}
```

becomes:

```elixir
alias SymphonyElixir.{Config, PathSafety}
```

- [ ] **Step 2: Delete every function head guarded by `when is_binary(worker_host)`**

Using grep results from recon, the SSH-only heads are at lines: 48 (`ensure_workspace`), 108 (`remove`), 134 (`remove_issue_workspaces`), plus any helpers like `run_remote_command/3`, `remote_workspace_path/2`. Delete those clauses entirely. Then drop the `worker_host` parameter from the surviving local clauses + their public-API typespecs.

Public API after strip:

```elixir
@spec create_for_issue(map() | String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
def create_for_issue(issue_or_identifier) do
  # ... existing body with worker_host removed
end

@spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
def remove(workspace) do
  # ... local body
end

@spec remove_issue_workspaces(term()) :: :ok
def remove_issue_workspaces(identifier) when is_binary(identifier) do
  # ... local body
end
```

Internal helpers `workspace_path_for_issue/2`, `validate_workspace_path/2`, `ensure_workspace/2`, `maybe_run_after_create_hook/4`, `maybe_run_before_remove_hook/2` lose their `worker_host` parameter. Anything calling `run_remote_command` is deleted with the surrounding helper.

Hook helpers (`run_before_run_hook`, `run_after_run_hook`) that previously took `worker_host` — drop the param, run hooks locally only.

- [ ] **Step 3: Compile + run workspace test**

```bash
mix compile --warnings-as-errors 2>&1 | tail -10
mix test test/symphony_elixir/workspace_and_config_test.exs 2>&1 | tail -5
```

Expected: clean. If tests pass `worker_host` to workspace functions, update those test setups (drop the arg).

- [ ] **Step 4: Commit**

```bash
git add lib/symphony_elixir/workspace.ex test/symphony_elixir/workspace_and_config_test.exs
git commit -m "refactor(workspace): strip SSH branches (local-only)"
git push
```

---

## Task 5: Strip multi-host from `orchestrator.ex` (worker_host display field stays)

**Files:**
- Modify: `lib/symphony_elixir/orchestrator.ex` (1655 LOC → ~1450 LOC)

- [ ] **Step 1: Find every `worker_host` reference in orchestrator.ex**

```bash
grep -n "worker_host\|ssh_hosts\|SSH\|max_concurrent_agents_per_host\|max_concurrent_agents_by_state" lib/symphony_elixir/orchestrator.ex
```

Expected output: ~10-15 lines covering: running_entry field display (lines 142, 154 from recon), config-driven worker selection lookups (`Config.settings!().worker.ssh_hosts`), per-state concurrency caps (`max_concurrent_agents_by_state`), retry-distributed paths (if any reference `:remote_*` reasons).

- [ ] **Step 2: Surgical edits**

For each match:
- `running_entry.worker_host` field references in formatting/dispatch — REPLACE with literal `nil` or DELETE the reference (workpad already handles `nil` via `Map.get(running_entry, :worker_host) || "local"`)
- `Config.settings!().worker.ssh_hosts` — DELETE the line and any branch it gates
- `max_concurrent_agents_per_host` reads — DELETE
- `max_concurrent_agents_by_state` reads — DELETE the per-state cap branch in dispatch decision; keep simple global cap (`max_concurrent_agents`)

If a function exists called `select_worker_host/2` or similar, DELETE it.

After edit, the orchestrator's dispatch decision becomes:

```elixir
defp can_dispatch_more?(state) do
  cap = Config.settings!().agent.max_concurrent_agents
  map_size(state.running) < cap
end
```

(One global cap. No per-host, no per-state. If you find `can_dispatch_more?` already exists with more logic, simplify to the above.)

- [ ] **Step 3: Compile + run orchestrator tests**

```bash
mix compile --warnings-as-errors 2>&1 | tail -10
mix test test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/core_test.exs 2>&1 | tail -5
```

Expected: green. If a test depends on `max_concurrent_agents_by_state` or per-host caps, delete that test (the feature is gone).

- [ ] **Step 4: Commit**

```bash
git add lib/symphony_elixir/orchestrator.ex test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/core_test.exs
git commit -m "refactor(orchestrator): strip multi-host + per-state caps (single global concurrency cap)"
git push
```

---

## Task 6: Strip multi-host fields from `config/schema.ex`

**Files:**
- Modify: `lib/symphony_elixir/config/schema.ex` (557 LOC → ~470 LOC)

- [ ] **Step 1: Delete the `Worker` embedded schema entirely**

Lines 108-128 region (the `defmodule Worker do … end` containing `ssh_hosts`, `max_concurrent_agents_per_host`). Delete the whole module.

Then delete the `embeds_one(:worker, Worker, ...)` line in the parent schema (around line 268) and the `cast_embed(:worker, with: &Worker.changeset/2)` line (around line 360).

- [ ] **Step 2: Delete `max_concurrent_agents_by_state` field + its validation**

Lines 134, 142, 148-149 region. Drop:
- `field(:max_concurrent_agents_by_state, :map, default: %{})`
- `:max_concurrent_agents_by_state` from the `cast` field list
- `update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)`
- `Schema.validate_state_limits(:max_concurrent_agents_by_state)`

If `normalize_state_limits/1` and `validate_state_limits/2` are now unused, delete those helpers too (grep first to confirm).

- [ ] **Step 3: Compile + targeted tests**

```bash
mix compile --warnings-as-errors 2>&1 | tail -10
mix test test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/extensions_test.exs 2>&1 | tail -5
```

Expected: green. Tests asserting on the deleted fields fail — delete those assertions or whole test cases.

- [ ] **Step 4: Commit**

```bash
git add lib/symphony_elixir/config/schema.ex test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/extensions_test.exs
git commit -m "refactor(config): drop Worker.ssh_hosts + per-state caps from schema"
git push
```

---

## Task 7: Delete `ssh.ex` (now no callers)

**Files:**
- Delete: `lib/symphony_elixir/ssh.ex` (100 LOC)
- Delete: `test/symphony_elixir/ssh_test.exs` (199 LOC)

- [ ] **Step 1: Confirm zero remaining callers**

```bash
grep -rn "SymphonyElixir.SSH\|alias.*SSH\b" lib/ --include="*.ex"
```

Expected output: empty (Tasks 3+4 should have removed all references).

- [ ] **Step 2: Delete files + recheck `live_e2e_test.exs`**

```bash
rm lib/symphony_elixir/ssh.ex test/symphony_elixir/ssh_test.exs
grep -n "SSH" test/symphony_elixir/live_e2e_test.exs
```

If `live_e2e_test.exs` still references SSH, that test will be deleted in Task 9 (Phoenix live e2e goes with the web tree). Don't edit it now — let Task 9 handle it.

- [ ] **Step 3: Compile + targeted tests**

```bash
mix compile --warnings-as-errors 2>&1 | tail -10
```

Expected: clean. (Don't run full suite — `live_e2e_test.exs` may break, that's OK, gets deleted in Task 9.)

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore(strip): delete ssh.ex (unused after multi-host strip)"
git push
```

---

## Task 8: Strip `StatusDashboard` references from production code

**Files:**
- Modify: `lib/symphony_elixir.ex` (47 LOC, drop StatusDashboard alias/start)
- Modify: `lib/symphony_elixir/orchestrator.ex` (drop StatusDashboard.* calls)

- [ ] **Step 1: Find StatusDashboard usages outside the deletion targets**

```bash
grep -n "StatusDashboard" lib/symphony_elixir.ex lib/symphony_elixir/orchestrator.ex
```

- [ ] **Step 2: Edit `lib/symphony_elixir.ex` to remove StatusDashboard from supervision tree**

Find any line like:

```elixir
{SymphonyElixir.StatusDashboard, []},
```

in the `children = [...]` list and DELETE it. Also drop any `alias` line referencing `StatusDashboard`.

- [ ] **Step 3: Edit `lib/symphony_elixir/orchestrator.ex` — remove StatusDashboard.* function calls**

Each call site is a side-effect "broadcast/notify dashboard" that produces no behaviour change when removed. DELETE those lines (do not replace with anything).

Verify with:

```bash
grep -n "StatusDashboard" lib/
```

Expected: only `lib/symphony_elixir/status_dashboard.ex` itself (deleted in Task 9).

- [ ] **Step 4: Compile + targeted tests**

```bash
mix compile --warnings-as-errors 2>&1 | tail -10
mix test test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/core_test.exs 2>&1 | tail -5
```

Expected: green. (Snapshot test will break in Task 9 deletion.)

- [ ] **Step 5: Commit**

```bash
git add lib/symphony_elixir.ex lib/symphony_elixir/orchestrator.ex
git commit -m "refactor: drop StatusDashboard from supervision + orchestrator broadcasts"
git push
```

---

## Task 9: Delete TUI `status_dashboard.ex` + Phoenix web tree + `http_server.ex`

**Files:**
- Delete: `lib/symphony_elixir/status_dashboard.ex` (1952 LOC)
- Delete: `lib/symphony_elixir/http_server.ex` (88 LOC, Phoenix endpoint launcher)
- Delete: `lib/symphony_elixir_web/` ENTIRE directory (router, endpoint, controllers, layouts, live, presenter, observability_pubsub, static_assets, error_html, error_json)
- Delete: `test/symphony_elixir/status_dashboard_snapshot_test.exs` (288 LOC)
- Delete: `test/symphony_elixir/live_e2e_test.exs` (802 LOC)
- Delete: `test/symphony_elixir/observability_pubsub_test.exs` (28 LOC)
- Delete: `test/support/snapshot_support.exs` (78 LOC, only used by snapshot test)
- Modify: `lib/symphony_elixir.ex` — drop `HttpServer` from supervision children
- Modify: `mix.exs` — drop `:phoenix`, `:phoenix_live_view`, `:bandit`, `:phoenix_html` deps if listed
- Modify: `test/support/test_support.exs` — drop `stop_default_http_server/0` and any imports

- [ ] **Step 1: Drop HttpServer from supervision in `lib/symphony_elixir.ex`**

Find and DELETE the line `{SymphonyElixir.HttpServer, []}` (or similar) from the `children` list.

- [ ] **Step 2: Bulk delete files**

```bash
rm lib/symphony_elixir/status_dashboard.ex
rm lib/symphony_elixir/http_server.ex
rm -rf lib/symphony_elixir_web/
rm test/symphony_elixir/status_dashboard_snapshot_test.exs
rm test/symphony_elixir/live_e2e_test.exs
rm test/symphony_elixir/observability_pubsub_test.exs
rm test/support/snapshot_support.exs
```

- [ ] **Step 3: Edit `test/support/test_support.exs` to drop now-broken helpers**

Find `stop_default_http_server/0` and DELETE the function (and any module attributes / imports referencing Phoenix Endpoint or HttpServer). Then find any `import` line exporting `stop_default_http_server: 0` and remove it from the export list.

Also find:

```elixir
@endpoint SymphonyElixirWeb.Endpoint
```

if present in test_support, DELETE.

- [ ] **Step 4: Edit `test/symphony_elixir/extensions_test.exs` to delete sections that reference Phoenix Endpoint**

```bash
grep -n "SymphonyElixirWeb\|Endpoint" test/symphony_elixir/extensions_test.exs
```

Each section that asserts on the Endpoint or starts/stops it via `Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, ...)` — delete the whole `test "..." do … end` block. Confirmed sections live around lines 95-100, 678-683 from recon.

- [ ] **Step 5: Edit `mix.exs` — drop Phoenix-stack deps**

```bash
grep -n "phoenix\|bandit\|phoenix_live\|phoenix_html" mix.exs
```

DELETE every matched line in the `deps/0` function. Keep `:jason`, `:postgrex`, `:ecto`, `:tesla`, `:claude_agent` etc.

Run `mix deps.unlock --unused` after edit to clean lockfile:

```bash
mix deps.unlock --unused
```

- [ ] **Step 6: Compile + full suite**

```bash
mix compile --warnings-as-errors 2>&1 | tail -15
mix test 2>&1 | tail -15
```

Expected: clean compile, all remaining tests pass. If a stray test/file still references Web or HttpServer, fix it now (delete the assertion or the test).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "chore(strip): delete TUI dashboard + Phoenix web tree + http_server (UI gone)"
git push
```

---

## Task 10: Audit + drop dead query helpers from `linear/client.ex`

**Files:**
- Modify: `lib/symphony_elixir/linear/client.ex` (586 LOC → audit; expect ~400 LOC after dead-code strip)

- [ ] **Step 1: List all public functions in `linear/client.ex`**

```bash
grep -n "^  @spec\|^  def " lib/symphony_elixir/linear/client.ex
```

- [ ] **Step 2: For each public function, grep for callers in `lib/`**

```bash
for fn in $(grep "^  def \\([a-z_]*\\)" lib/symphony_elixir/linear/client.ex | sed 's/.*def \\([a-z_]*\\).*/\\1/'); do
  count=$(grep -rln "Linear.Client.$fn\|Client.$fn" lib/ test/ --include="*.ex" --include="*.exs" | grep -v linear/client.ex | wc -l | tr -d ' ')
  echo "$fn => $count callers"
done
```

- [ ] **Step 3: Delete public functions with 0 callers (and their private helpers if they become orphaned)**

For each "0 callers" entry, find the function definition + its `@spec` + any `defp` helpers it exclusively uses (grep them after deleting the public function), and remove. Be conservative: if a helper is shared, keep it.

- [ ] **Step 4: Compile + targeted tests**

```bash
mix compile --warnings-as-errors 2>&1 | tail -10
mix test test/symphony_elixir/extensions_test.exs 2>&1 | tail -5
```

If `linear/client.ex` has no dedicated test file, the broader test (extensions_test) is sufficient. Expected: green.

- [ ] **Step 5: Commit**

```bash
git add lib/symphony_elixir/linear/client.ex
git commit -m "refactor(linear/client): drop dead query helpers (no callers)"
git push
```

---

## Task 11: Split `orchestrator.ex` into focused modules

**Files (create):**
- Create: `lib/symphony_elixir/orchestrator/reconcile.ex`
- Create: `lib/symphony_elixir/orchestrator/pr_shutdown.ex`
- Create: `lib/symphony_elixir/orchestrator/workpad_sync.ex`
- Create: `lib/symphony_elixir/orchestrator/agent_lifecycle.ex`
- Modify: `lib/symphony_elixir/orchestrator.ex` (slim down to GenServer state + dispatch)

- [ ] **Step 1: Identify cohesive function clusters in `orchestrator.ex`**

```bash
wc -l lib/symphony_elixir/orchestrator.ex
grep -n "^  defp\\|^  def " lib/symphony_elixir/orchestrator.ex | head -60
```

Expected: file ~1450 LOC after Task 5 strip. Functions should naturally cluster:
- Reconcile cluster: `reconcile_*`, `find_candidate_*`, `dispatch_*`, `revalidate_*` (poll-driven state machine)
- PR-shutdown cluster (Sprint 3): `mark_pending_pr_shutdown`, `maybe_finalize_pending_pr_shutdown`, `pending_pr_shutdown_finalization_event?`, `cancel_pending_pr_shutdown_timer`, `handle_pending_pr_shutdown_down`, `handle_regular_down`
- Workpad cluster: anything calling `Workpad.maybe_sync` glue, `:workpad_comment_created` reply handling
- Agent lifecycle cluster: agent spawn under `Task.Supervisor`, `:DOWN` routing, retry/backoff

- [ ] **Step 2: Create `lib/symphony_elixir/orchestrator/pr_shutdown.ex`**

Move the Sprint 3 PR-shutdown helpers out. Module should expose pure-ish functions (state in, state out) so orchestrator.ex calls them like `state = PrShutdown.mark(state, issue_id)`. Example skeleton:

```elixir
defmodule SymphonyElixir.Orchestrator.PrShutdown do
  @moduledoc """
  Deferred-shutdown handshake: orchestrator marks `pending_pr_shutdown`
  on `pr_attached` and finalises (drain tokens + sync workpad + terminate)
  on the next `turn_completed`. 30s timeout fallback if the SDK hangs.
  Sprint 3 / Bug 3 root fix.
  """

  alias SymphonyElixir.Orchestrator.AgentLifecycle
  alias SymphonyElixir.Workpad

  @timeout_ms 30_000

  def mark(state, issue_id) do
    # ... move body of orchestrator.ex's `mark_pending_pr_shutdown/2` here
  end

  def maybe_finalize(state, issue_id, update) do
    # ... move body of orchestrator.ex's `maybe_finalize_pending_pr_shutdown/3`
  end

  def finalization_event?(update) do
    # ... move body of `pending_pr_shutdown_finalization_event?/1`
  end

  def cancel_timer(running_entry) do
    # ... move body of `cancel_pending_pr_shutdown_timer/1`
  end

  def handle_down(state, issue_id, running_entry, reason) do
    # ... move body of `handle_pending_pr_shutdown_down/4`
  end
end
```

(Move actual function bodies — don't reimplement. Use Read + Edit, not Write-from-scratch.)

In `orchestrator.ex`, replace each old call site:
- `mark_pending_pr_shutdown(state, issue_id)` → `PrShutdown.mark(state, issue_id)`
- `maybe_finalize_pending_pr_shutdown(state, issue_id, update)` → `PrShutdown.maybe_finalize(state, issue_id, update)`
- etc.

Add `alias SymphonyElixir.Orchestrator.PrShutdown` near the top of `orchestrator.ex`.

- [ ] **Step 3: Compile + run Sprint 3 tests to verify PR-shutdown still works**

```bash
mix compile --warnings-as-errors 2>&1 | tail -10
mix test test/symphony_elixir/orchestrator_status_test.exs --only "pending_pr_shutdown" 2>&1 | tail -5
mix test test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/core_test.exs 2>&1 | tail -5
```

Expected: green. PR-shutdown handshake intact.

- [ ] **Step 4: Commit PR-shutdown extraction**

```bash
git add lib/symphony_elixir/orchestrator/pr_shutdown.ex lib/symphony_elixir/orchestrator.ex
git commit -m "refactor(orchestrator): extract PR-shutdown handshake into orchestrator/pr_shutdown.ex"
git push
```

- [ ] **Step 5: Repeat Steps 2–4 for `workpad_sync.ex`**

Extract: workpad sync glue (`:workpad_comment_created` handling, integrate workpad updates into running_entry, etc).

```bash
mix compile --warnings-as-errors 2>&1 | tail -10
mix test test/symphony_elixir/orchestrator_status_test.exs 2>&1 | tail -5
git add lib/symphony_elixir/orchestrator/workpad_sync.ex lib/symphony_elixir/orchestrator.ex
git commit -m "refactor(orchestrator): extract workpad sync glue into orchestrator/workpad_sync.ex"
git push
```

- [ ] **Step 6: Repeat for `agent_lifecycle.ex`**

Extract: agent spawn under Task.Supervisor, `:DOWN` regular handler (the non-pending branch), retry/backoff scheduling.

```bash
mix compile --warnings-as-errors 2>&1 | tail -10
mix test test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/core_test.exs 2>&1 | tail -5
git add lib/symphony_elixir/orchestrator/agent_lifecycle.ex lib/symphony_elixir/orchestrator.ex
git commit -m "refactor(orchestrator): extract agent lifecycle into orchestrator/agent_lifecycle.ex"
git push
```

- [ ] **Step 7: Repeat for `reconcile.ex`**

Extract: `reconcile_*` family + dispatch decision (`can_dispatch_more?`) + candidate fetch + state-revalidation. This is the largest cluster — expect orchestrator.ex to drop from ~1100 LOC to ~400 LOC after this extraction.

```bash
mix compile --warnings-as-errors 2>&1 | tail -10
mix test test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/core_test.exs 2>&1 | tail -5
git add lib/symphony_elixir/orchestrator/reconcile.ex lib/symphony_elixir/orchestrator.ex
git commit -m "refactor(orchestrator): extract reconcile loop into orchestrator/reconcile.ex"
git push
```

- [ ] **Step 8: Verify final orchestrator.ex shape**

```bash
wc -l lib/symphony_elixir/orchestrator.ex lib/symphony_elixir/orchestrator/*.ex
```

Expected: orchestrator.ex < 400 LOC, each extracted module < 400 LOC. File-too-long warning gone.

```bash
mix compile --warnings-as-errors 2>&1 | tail -5
```

Expected: zero warnings.

---

## Task 12: Full verification + final LOC tally

- [ ] **Step 1: Lint / format**

```bash
mix format --check-formatted 2>&1 | tail -5
mix credo --strict 2>&1 | tail -10
```

Expected: format clean, credo clean (or unchanged from baseline pre-strip).

- [ ] **Step 2: Full test suite**

```bash
mix test 2>&1 | tail -5
```

Expected: 0 failures, 0 invalid. Test count will be lower than baseline (deleted modules took their tests).

- [ ] **Step 3: LOC tally**

```bash
echo "=== lib/ ==="; find lib -name "*.ex" | xargs wc -l | tail -1
echo "=== priv/ ==="; find priv -name "*.ex" -o -name "*.py" | xargs wc -l | tail -1
echo "=== test/ ==="; find test -name "*.exs" | xargs wc -l | tail -1
```

Expected: lib/ under 4k LOC. Compare to pre-strip baseline (lib/ was ~9.5k).

- [ ] **Step 4: Commit any final fixups (e.g., stray formatting)**

```bash
git status
# if changes exist
git add -A
git commit -m "chore(strip): final formatting + cleanup"
git push
```

---

## Task 13: E2E validation — multi-agent concurrent local

**Goal:** Prove that after strip, `max_concurrent_agents: 3` parallelises 3 issues on a single BEAM.

- [ ] **Step 1: Edit `WORKFLOW.schools-out.md` agent block**

Change:

```yaml
agent:
  max_concurrent_agents: 1
  max_turns: 25
```

To:

```yaml
agent:
  max_concurrent_agents: 3
  max_turns: 25
```

- [ ] **Step 2: Stage 3 sandbox issues in Linear**

Use the Linear API (via launcher) to create or move 3 small test issues into the symphony-e2e-sandbox project, all assigned to the workflow assignee, all in `Scheduled` state. Suggested 3 trivial repo-hygiene tasks (e.g., "add comment to README line N").

```bash
source ~/.symphony/launch.sh
# Create 3 sandbox issues — actual mutation depends on what's available.
# Move 3 existing issues if easier:
for issue_id in <id1> <id2> <id3>; do
  curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"mutation { issueUpdate(id: \\\"$issue_id\\\", input: { stateId: \\\"25ecde43-9926-479f-86ce-969284486a96\\\" }) { success } }\"}"
done
```

(`25ecde43-9926-479f-86ce-969284486a96` = "Scheduled" state for SODEV team, captured during Sprint 3 e2e.)

- [ ] **Step 3: Boot BEAM**

```bash
cd /Users/vini/Developer/symphony/elixir
source ~/.symphony/launch.sh && SYMPHONY_WORKFLOW_FILE=WORKFLOW.schools-out.md mix run --no-halt 2>&1 | tee /tmp/strip-down-e2e.log &
```

(Run in background, monitor.)

- [ ] **Step 4: Verify 3 agents pick up concurrently within first 30 seconds**

```bash
sleep 30
grep "Starting agent run" /tmp/strip-down-e2e.log | head -5
```

Expected: 3 distinct "Starting agent run for SODEV-XXX" log lines within the 30s window.

- [ ] **Step 5: Wait for all 3 to complete + verify each opened a PR**

Allow up to 30 minutes. Check via Linear API that all 3 issues moved to `In QA / Review` and have a GitHub attachment with a PR URL.

```bash
source ~/.symphony/launch.sh
for issue_id in <id1> <id2> <id3>; do
  curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"query { issue(id: \\\"$issue_id\\\") { identifier state { name } attachments { nodes { url } } } }\"}" | python3 -m json.tool
done
```

Expected: all 3 issues `state.name == "In QA / Review"`, each with a PR URL attachment.

- [ ] **Step 6: Stop BEAM + cleanup**

```bash
pkill -f "mix run --no-halt"
sleep 2
pgrep -lf "symphony_agent_shim"  # expect empty
```

- [ ] **Step 7: Reset `max_concurrent_agents` if you don't want to keep it at 3 by default**

Optional. If 3 is the new default, leave it. If 1 was deliberate, revert the workflow edit.

- [ ] **Step 8: Final commit + push**

```bash
git add WORKFLOW.schools-out.md
git commit -m "feat(workflow): bump max_concurrent_agents to 3 (multi-agent local validated)"
git push
```

---

## Task 15: Inject devflow guardrails into agent system prompt (Caminho A)

**Files:**
- Modify: `priv/agent_shim/src/symphony_agent_shim/thread.py`

**Goal:** Force the Symphony agent to follow TDD + atomic commits + no drive-by refactor by injecting hard rules into the SDK system prompt at thread start.

- [ ] **Step 1: Locate system_prompt construction in thread.py**

```bash
grep -n "system_prompt\|systemPrompt" priv/agent_shim/src/symphony_agent_shim/thread.py
```

- [ ] **Step 2: Prepend devflow rules to whatever system_prompt is passed**

Edit thread.py at the spot where `ClaudeAgentOptions(...)` or equivalent constructs the SDK options. Add a constant near the top of the file:

```python
DEVFLOW_RULES = """
You operate under devflow lite. Hard rules enforced by the harness:

1. TDD mandatory for code changes:
   - Write the failing test first
   - Run it, confirm it fails for the right reason
   - Implement the minimum to make it pass
   - Run the test, confirm it passes
   - Refactor if needed; tests must stay green

2. Atomic commits:
   - One behavior per commit
   - Descriptive message starting with type(scope): subject
   - Stage only files relevant to the commit; never `git add .` blindly

3. No drive-by refactor:
   - Stay strictly in the scope defined by the issue
   - Do not rename, reformat, or reorganize unrelated code
   - If you spot tech debt, note it in the PR description, do not fix it

4. Verify before commit:
   - Run the project's lint and the relevant test file
   - If either is red, do not commit; fix or revert

5. Comments:
   - Default to no comments
   - Only add a comment when WHY is non-obvious

These rules are enforced by harness gates downstream. Skipping them will cause your commits to fail.
"""
```

Then in the function that builds `ClaudeAgentOptions` (likely accepting a `system_prompt` param from the orchestrator), prepend `DEVFLOW_RULES` to whatever `system_prompt` arrives:

```python
effective_system_prompt = DEVFLOW_RULES + "\n\n" + (params.get("system_prompt") or "")
```

(Pass `effective_system_prompt` into `ClaudeAgentOptions(system_prompt=effective_system_prompt, ...)`. If the orchestrator passes the prompt via a different field, mirror that.)

- [ ] **Step 3: Run shim unit tests**

```bash
cd priv/agent_shim
.venv/bin/python -m pytest -x -q 2>&1 | tail -10
```

Expected: green. If a test asserts on the exact system_prompt content, update it to assert that DEVFLOW_RULES is a prefix.

- [ ] **Step 4: Commit**

```bash
git add priv/agent_shim/src/symphony_agent_shim/thread.py priv/agent_shim/tests/
git commit -m "feat(shim): inject devflow rules into agent system_prompt (TDD + atomic commits + no drive-by)"
git push
```

---

## Task 16: Pre-commit hook in workspace setup (Caminho C — defesa em profundidade)

**Files:**
- Modify: `lib/symphony_elixir/workspace.ex` (post-Task 4 shape)

**Goal:** Install a `.git/hooks/pre-commit` script in every workspace right after clone, so `git commit` from the agent fails if `mix format --check` or the relevant test file fails. Independent of agent cooperation — invariant enforced by git itself.

- [ ] **Step 1: Identify the workspace setup hook in workspace.ex**

After Task 4, `workspace.ex` exposes `create_for_issue/1` and a private `maybe_run_after_create_hook/3` that runs the YAML `hooks.after_create` script. We want to install the pre-commit hook AFTER the clone happens but in a way that respects the project's own pre-commit setup if any.

- [ ] **Step 2: Add `install_pre_commit_gate/1` private helper**

Append to `lib/symphony_elixir/workspace.ex` (after the existing `maybe_run_after_create_hook` block):

```elixir
@pre_commit_script ~S"""
#!/usr/bin/env bash
# devflow-injected pre-commit gate — blocks commits with broken format/tests
set -e

if [ -f mix.exs ]; then
  mix format --check-formatted || {
    echo "[devflow] mix format --check-formatted failed; run \"mix format\" before committing"
    exit 1
  }
fi

# Run only the test files staged for this commit + their inferred test counterparts.
# Conservative: if we can't infer, skip — never block on missing test infra.
staged_lib_files=$(git diff --cached --name-only --diff-filter=ACM | grep -E '^lib/.*\.(ex|exs)$' || true)
if [ -n "$staged_lib_files" ] && [ -d test ]; then
  test_files=""
  for f in $staged_lib_files; do
    base=$(basename "$f" | sed 's/\.exs\?$//')
    candidate="test/${base}_test.exs"
    if [ -f "$candidate" ]; then test_files="$test_files $candidate"; fi
    candidate2=$(echo "$f" | sed 's|^lib/|test/|; s|\.exs\?$|_test.exs|')
    if [ -f "$candidate2" ] && [ "$candidate2" != "$candidate" ]; then test_files="$test_files $candidate2"; fi
  done
  if [ -n "$test_files" ]; then
    mix test $test_files || {
      echo "[devflow] targeted test failed; fix before committing"
      exit 1
    }
  fi
fi
"""

defp install_pre_commit_gate(workspace) when is_binary(workspace) do
  hook_path = Path.join([workspace, ".git", "hooks", "pre-commit"])
  hook_dir = Path.dirname(hook_path)

  with :ok <- File.mkdir_p(hook_dir),
       :ok <- File.write(hook_path, @pre_commit_script),
       :ok <- File.chmod(hook_path, 0o755) do
    :ok
  else
    {:error, reason} ->
      Logger.warning("Failed to install devflow pre-commit gate at #{hook_path}: #{inspect(reason)}")
      :ok
  end
end
```

Then call `install_pre_commit_gate(workspace)` from `create_for_issue/1` immediately after `maybe_run_after_create_hook` succeeds and before returning `{:ok, workspace}`.

- [ ] **Step 3: Add a test in `test/symphony_elixir/workspace_and_config_test.exs`**

```elixir
test "create_for_issue installs devflow pre-commit gate in cloned workspace" do
  # ... setup that drives create_for_issue/1 with a stub clone
  {:ok, workspace} = Workspace.create_for_issue(stub_issue)
  hook = Path.join([workspace, ".git", "hooks", "pre-commit"])
  assert File.exists?(hook)
  assert {:ok, %{mode: mode}} = File.stat(hook)
  assert (mode &&& 0o111) != 0, "pre-commit hook must be executable"
  body = File.read!(hook)
  assert body =~ "[devflow] mix format --check-formatted failed"
end
```

(If the existing test file already has clone stubbing infrastructure, mirror it. If not, mark this test as `@tag :integration` and rely on real clone — slower but covers the wire.)

- [ ] **Step 4: Verify**

```bash
mix compile --warnings-as-errors 2>&1 | tail -5
mix test test/symphony_elixir/workspace_and_config_test.exs 2>&1 | tail -5
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add lib/symphony_elixir/workspace.ex test/symphony_elixir/workspace_and_config_test.exs
git commit -m "feat(workspace): install devflow pre-commit gate (.git/hooks) on every workspace"
git push
```

---

## Task 14: Open PR to main

- [ ] **Step 1: Open PR via gh CLI**

```bash
gh pr create --base main --head feature/symphony-strip-down \
  --title "Symphony strip-down: cut UI + multi-host machinery" \
  --body "$(cat <<'EOF'
## Summary

- Deleted unused machinery: TUI status_dashboard.ex, Phoenix web tree, http_server, ssh.ex, specs_check
- Stripped multi-host (SSH-to-remote-worker) from orchestrator, agent_runner, workspace, codex/app_server, config/schema
- Preserved: Sprint 3 deferred-shutdown handshake, multi-AGENT local concurrency (validated max_concurrent_agents=3)
- Split orchestrator.ex into focused modules (reconcile, pr_shutdown, workpad_sync, agent_lifecycle)
- LOC: lib/ ~9.5k → ~3k

## Test plan

- [x] Full `mix test` green
- [x] `mix compile --warnings-as-errors` clean
- [x] E2E: 3 sandbox issues processed concurrently on single BEAM, 3 PRs opened
- [x] Sprint 3 PR-shutdown tests still green
EOF
)"
```

Expected: PR URL printed.

---

## Self-review (post-write)

**Spec coverage:**
- ✅ Delete status_dashboard, ssh, specs_check, web tree, http_server (Tasks 1, 7, 9)
- ✅ Reduce orchestrator, agent_runner, workspace, codex/app_server, config/schema (Tasks 2-6)
- ✅ Split orchestrator (Task 11)
- ✅ Preserve Sprint 3 PR-shutdown (Task 11 keeps it intact via PrShutdown module + dedicated test gate)
- ✅ Multi-agent local concurrency verified (Task 13)
- ✅ Multi-host removed but multi-agent preserved
- ✅ Tracker behaviour KEPT (decision documented in "Decisions locked in")
- ✅ Shim sandbox NOT touched (decision documented)
- ⚠️ ~/Developer/symphony-ui rm: NOT in plan. That's a separate dir/repo. Surface as a manual one-liner at end of execution, not as a task (no risk in keeping the directory unmaintained).

**Placeholder scan:** No "TBD"/"implement later". Each surgery step shows the actual before/after code OR exact grep + delete commands.

**Type consistency:** `worker_host` parameter dropped consistently across Tasks 2-6 (agent_runner, codex/app_server, workspace, orchestrator). `workpad.ex:181` already handles `nil` worker_host via `|| "local"` — no change needed there.

**Risk areas:**
- Task 9 deletes the entire web tree in one commit — large blast radius. Justified because the web tree is internally cohesive and partial deletes leave broken supervision tree.
- Task 11 is a 4-step extraction; each sub-step commits independently so a regression is bisectable to one extraction.
- Task 13 hits real Linear + real GitHub repo (schoolsoutapp/schools-out). Use sandbox project. Coordinate with María if 3 PRs on the repo would be noise.
