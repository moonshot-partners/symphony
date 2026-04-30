# Symphony UI MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a read-only kanban UI brick (separate repo `symphony-ui`) that watches Symphony's Linear-driven agent work in real time, plugged into the existing Phoenix observability API via 2 new endpoints.

**Architecture:** Symphony backend (Elixir, this repo) gains `/api/v1/board` (issues grouped by Linear state) + `/api/v1/stream` (SSE consuming `ObservabilityPubSub`) + CORS for `localhost:3000`. UI (Next.js 15 + TS + Tailwind v4 + shadcn/ui in a sibling repo `~/Developer/symphony-ui`) renders 3 kanban columns with active-card animation (variant B: progress ring + last_event line) and uses TanStack Query + `@microsoft/fetch-event-source` to refetch on every PubSub tick.

**Tech Stack:** Elixir 1.19 / Phoenix 1.8 / Bandit (existing) · Next.js 15 / TypeScript / Tailwind v4 / shadcn/ui / TanStack Query v5 / `@microsoft/fetch-event-source` / framer-motion 12 / pnpm

---

## Phase 1 — Backend API (Elixir, this repo)

All work is in `/Users/vini/Developer/symphony/elixir`. Branch: `feature/codex-to-claude-migration` (already checked out, non-protected, auto-push allowed).

### Task 1.1: Extend `Linear.Issue` struct with assignee name fields

**Files:**
- Modify: `elixir/lib/symphony_elixir/linear/issue.ex` (full rewrite)
- Modify: `elixir/lib/symphony_elixir/linear/client.ex:464-484` (`normalize_issue/2`)
- Test: `elixir/test/symphony_elixir/core_test.exs` (add to existing — find existing `Issue` tests; if none, create section)

- [ ] **Step 1.1.1: Read existing Issue tests**

```bash
grep -n "Issue" /Users/vini/Developer/symphony/elixir/test/symphony_elixir/core_test.exs | head -20
grep -n "normalize_issue_for_test\|normalize_issue\b" /Users/vini/Developer/symphony/elixir/test -r | head
```

Note where the closest existing test for `Linear.Client.normalize_issue_for_test/1,2` lives. That test file is the right home for new struct-shape assertions.

- [ ] **Step 1.1.2: Write the failing test**

Add this test alongside the existing normalize_issue tests (likely in `core_test.exs`):

```elixir
test "normalize_issue keeps assignee name and display_name" do
  raw = %{
    "id" => "issue-1",
    "identifier" => "SODEV-1",
    "title" => "T",
    "state" => %{"name" => "Todo"},
    "assignee" => %{
      "id" => "user-1",
      "name" => "Vini Freitas",
      "displayName" => "vini",
      "email" => "v@example.com"
    },
    "labels" => %{"nodes" => []},
    "attachments" => %{"nodes" => []},
    "inverseRelations" => %{"nodes" => []}
  }

  issue = SymphonyElixir.Linear.Client.normalize_issue_for_test(raw)

  assert issue.assignee_id == "user-1"
  assert issue.assignee_name == "Vini Freitas"
  assert issue.assignee_display_name == "vini"
end
```

- [ ] **Step 1.1.3: Run test to verify it fails**

```bash
cd /Users/vini/Developer/symphony/elixir
mix test test/symphony_elixir/core_test.exs --only line:<line_of_new_test>
```

Expected: FAIL with "key :assignee_name not found in struct ... Linear.Issue".

- [ ] **Step 1.1.4: Update `Linear.Issue` struct**

Replace the entirety of `elixir/lib/symphony_elixir/linear/issue.ex` with:

```elixir
defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized Linear issue representation used by the orchestrator.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :assignee_name,
    :assignee_display_name,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    has_pr_attachment: false,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          assignee_name: String.t() | nil,
          assignee_display_name: String.t() | nil,
          labels: [String.t()],
          assigned_to_worker: boolean(),
          has_pr_attachment: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end
end
```

- [ ] **Step 1.1.5: Update `normalize_issue/2` in `client.ex`**

In `elixir/lib/symphony_elixir/linear/client.ex`, change `normalize_issue/2` (around line 464) to populate the two new fields. Replace the function body's `%Issue{...}` literal with:

```elixir
  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      assignee_name: assignee_field(assignee, "name"),
      assignee_display_name: assignee_field(assignee, "displayName"),
      blocked_by: extract_blockers(issue),
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      has_pr_attachment: pr_attachment?(issue),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end
```

- [ ] **Step 1.1.6: Run tests to verify all pass**

```bash
cd /Users/vini/Developer/symphony/elixir
mix test test/symphony_elixir/core_test.exs
```

Expected: all green. Watch for assertions in other Issue-using tests that might break — they shouldn't since we only added fields.

- [ ] **Step 1.1.7: Commit**

```bash
cd /Users/vini/Developer/symphony
git add elixir/lib/symphony_elixir/linear/issue.ex elixir/lib/symphony_elixir/linear/client.ex elixir/test/symphony_elixir/core_test.exs
git commit -m "$(cat <<'EOF'
feat(linear): keep assignee name and display_name on Issue struct

Board UI needs to render assignee initials. The GraphQL query already
asks for name/displayName; the normalizer was discarding them.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.2: Add `Presenter.board_payload/2`

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex` (add new function)
- Test: `elixir/test/symphony_elixir/extensions_test.exs` (extend with board_payload section)

The function signature: `board_payload(linear_module, orchestrator_server) :: map()` where `linear_module` is `Application.get_env(:symphony_elixir, :linear_client_module, SymphonyElixir.Linear.Adapter)` (so tests can stub) and `orchestrator_server` is a GenServer name.

- [ ] **Step 1.2.1: Write the failing test**

Append to `elixir/test/symphony_elixir/extensions_test.exs` inside an appropriate `describe` block (or new `describe "board_payload/2"`):

```elixir
describe "board_payload/2" do
  test "groups Linear issues by column and joins with running snapshot" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_module) end)

    Process.put({FakeLinearClient, :graphql_result}, nil)

    issues = [
      %SymphonyElixir.Linear.Issue{
        id: "i1", identifier: "SODEV-1", title: "Todo task",
        state: "Todo", url: "u1", priority: 2,
        assignee_id: "a1", assignee_name: "Ana", assignee_display_name: "ana",
        labels: ["seo"], has_pr_attachment: false
      },
      %SymphonyElixir.Linear.Issue{
        id: "i2", identifier: "SODEV-2", title: "Active task",
        state: "In Progress", url: "u2", priority: 1,
        assignee_id: "a2", assignee_name: "Bob", assignee_display_name: "bob",
        labels: [], has_pr_attachment: true
      },
      %SymphonyElixir.Linear.Issue{
        id: "i3", identifier: "SODEV-3", title: "Done task",
        state: "Done", url: "u3", priority: 3,
        assignee_id: nil, assignee_name: nil, assignee_display_name: nil,
        labels: [], has_pr_attachment: true
      }
    ]

    {:ok, fake_orch} =
      SymphonyElixir.ExtensionsTest.StaticOrchestrator.start_link(
        name: :"orch_#{System.unique_integer([:positive])}",
        snapshot: %{
          running: [
            %{
              issue_id: "i2",
              identifier: "SODEV-2",
              state: "In Progress",
              session_id: "sess-1",
              turn_count: 7,
              last_agent_event: "tool_use",
              last_agent_message: "writing test",
              last_agent_timestamp: ~U[2026-04-30 19:00:00Z],
              started_at: ~U[2026-04-30 18:55:00Z],
              agent_input_tokens: 1000,
              agent_output_tokens: 1400,
              agent_total_tokens: 2400
            }
          ],
          retrying: [],
          agent_totals: %{},
          rate_limits: nil
        }
      )

    payload =
      SymphonyElixirWeb.Presenter.board_payload(
        fn -> {:ok, issues} end,
        fake_orch,
        1_000
      )

    assert is_binary(payload.generated_at)
    assert length(payload.columns) == 3
    [todo, in_progress, done] = payload.columns

    assert todo.key == "todo"
    assert Enum.map(todo.issues, & &1.identifier) == ["SODEV-1"]

    assert in_progress.key == "in_progress"
    assert [active] = in_progress.issues
    assert active.identifier == "SODEV-2"
    assert active.agent_status.running == true
    assert active.agent_status.turn_count == 7
    assert active.agent_status.last_event == "writing test"

    assert done.key == "done"
    assert hd(done.issues).agent_status == nil
  end

  test "issue with retrying status maps to non-running agent_status" do
    {:ok, fake_orch} =
      SymphonyElixir.ExtensionsTest.StaticOrchestrator.start_link(
        name: :"orch_#{System.unique_integer([:positive])}",
        snapshot: %{
          running: [],
          retrying: [
            %{
              issue_id: "i9",
              identifier: "SODEV-9",
              attempt: 2,
              due_in_ms: 5000,
              error: "tool_failed"
            }
          ],
          agent_totals: %{},
          rate_limits: nil
        }
      )

    issues = [
      %SymphonyElixir.Linear.Issue{
        id: "i9", identifier: "SODEV-9", title: "Retrying task",
        state: "In Progress", url: "u9", priority: nil,
        assignee_id: nil, assignee_name: nil, assignee_display_name: nil,
        labels: [], has_pr_attachment: false
      }
    ]

    payload =
      SymphonyElixirWeb.Presenter.board_payload(
        fn -> {:ok, issues} end,
        fake_orch,
        1_000
      )

    [_todo, in_progress, _done] = payload.columns
    [issue] = in_progress.issues
    assert issue.agent_status.running == false
    assert issue.agent_status.retry_attempt == 2
    assert issue.agent_status.retry_reason == "tool_failed"
  end

  test "returns empty columns when linear fetch fails" do
    {:ok, fake_orch} =
      SymphonyElixir.ExtensionsTest.StaticOrchestrator.start_link(
        name: :"orch_#{System.unique_integer([:positive])}",
        snapshot: %{running: [], retrying: [], agent_totals: %{}, rate_limits: nil}
      )

    payload =
      SymphonyElixirWeb.Presenter.board_payload(
        fn -> {:error, :missing_linear_api_token} end,
        fake_orch,
        1_000
      )

    assert payload.error.code == "linear_unavailable"
    assert Enum.all?(payload.columns, &(&1.issues == []))
  end
end
```

The `board_payload/3` arity here uses an anonymous `fetcher` for direct injection — pragmatic for unit tests. The HTTP controller will use `board_payload/2` which calls `Linear.Adapter.fetch_issues_by_states/1` internally.

- [ ] **Step 1.2.2: Run tests to verify they fail**

```bash
cd /Users/vini/Developer/symphony/elixir
mix test test/symphony_elixir/extensions_test.exs --only describe:"board_payload/2"
```

Expected: FAIL — function not defined.

- [ ] **Step 1.2.3: Implement `board_payload/2` and `board_payload/3`**

Append to `elixir/lib/symphony_elixir_web/presenter.ex` (right after `refresh_payload/1`):

```elixir
  @board_columns [
    %{key: "todo", label: "Todo", linear_states: ["Backlog", "Todo"]},
    %{key: "in_progress", label: "In Progress", linear_states: ["In Progress", "In Review"]},
    %{key: "done", label: "Done", linear_states: ["Done", "Cancelled", "Canceled", "Duplicate"]}
  ]

  @spec board_payload(GenServer.name(), timeout()) :: map()
  def board_payload(orchestrator, snapshot_timeout_ms) do
    fetcher = fn ->
      states = Enum.flat_map(@board_columns, & &1.linear_states)
      SymphonyElixir.Tracker.fetch_issues_by_states(states)
    end

    board_payload(fetcher, orchestrator, snapshot_timeout_ms)
  end

  @spec board_payload((-> {:ok, [SymphonyElixir.Linear.Issue.t()]} | {:error, term()}), GenServer.name(), timeout()) :: map()
  def board_payload(fetcher, orchestrator, snapshot_timeout_ms) when is_function(fetcher, 0) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    snapshot = Orchestrator.snapshot(orchestrator, snapshot_timeout_ms)

    case fetcher.() do
      {:ok, issues} ->
        running_index = build_running_index(snapshot)
        retrying_index = build_retrying_index(snapshot)

        %{
          generated_at: generated_at,
          columns: build_columns(issues, running_index, retrying_index)
        }

      {:error, _reason} ->
        %{
          generated_at: generated_at,
          columns: empty_columns(),
          error: %{code: "linear_unavailable", message: "Linear API unreachable"}
        }
    end
  end

  defp build_running_index(%{} = snapshot), do: Map.new(snapshot.running, &{&1.issue_id, &1})
  defp build_running_index(_), do: %{}

  defp build_retrying_index(%{} = snapshot), do: Map.new(snapshot.retrying, &{&1.issue_id, &1})
  defp build_retrying_index(_), do: %{}

  defp empty_columns do
    Enum.map(@board_columns, fn %{key: k, label: l, linear_states: s} ->
      %{key: k, label: l, linear_states: s, issues: []}
    end)
  end

  defp build_columns(issues, running_index, retrying_index) do
    Enum.map(@board_columns, fn %{key: k, label: l, linear_states: states} ->
      column_issues =
        issues
        |> Enum.filter(&(&1.state in states))
        |> Enum.map(&board_issue_payload(&1, running_index, retrying_index))

      %{key: k, label: l, linear_states: states, issues: column_issues}
    end)
  end

  defp board_issue_payload(issue, running_index, retrying_index) do
    %{
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      url: issue.url,
      state: issue.state,
      priority: issue.priority,
      labels: issue.labels,
      has_pr_attachment: issue.has_pr_attachment,
      assignee: assignee_payload(issue),
      agent_status: agent_status_payload(issue.id, running_index, retrying_index)
    }
  end

  defp assignee_payload(%{assignee_id: nil}), do: nil

  defp assignee_payload(issue) do
    %{
      id: issue.assignee_id,
      name: issue.assignee_name,
      display_name: issue.assignee_display_name
    }
  end

  defp agent_status_payload(issue_id, running_index, retrying_index) do
    cond do
      Map.has_key?(running_index, issue_id) ->
        running = running_index[issue_id]

        %{
          running: true,
          session_id: running.session_id,
          turn_count: Map.get(running, :turn_count, 0),
          last_event: summarize_message(running.last_agent_message),
          started_at: iso8601(running.started_at),
          last_event_at: iso8601(running.last_agent_timestamp),
          tokens: %{total_tokens: running.agent_total_tokens}
        }

      Map.has_key?(retrying_index, issue_id) ->
        retry = retrying_index[issue_id]

        %{
          running: false,
          retry_attempt: retry.attempt,
          retry_reason: Map.get(retry, :error)
        }

      true ->
        nil
    end
  end
```

(`Orchestrator`, `summarize_message/1`, `iso8601/1` are already aliased / defined in this module from earlier edits.)

- [ ] **Step 1.2.4: Run all presenter tests**

```bash
cd /Users/vini/Developer/symphony/elixir
mix test test/symphony_elixir/extensions_test.exs --only describe:"board_payload/2"
```

Expected: 3 PASS.

- [ ] **Step 1.2.5: Run full suite to ensure no regression**

```bash
mix test
```

Expected: all green. Coverage threshold check: `Presenter` is in `ignore_modules` per `mix.exs`, so we are not blocked by 100% threshold.

- [ ] **Step 1.2.6: Commit**

```bash
git add elixir/lib/symphony_elixir_web/presenter.ex elixir/test/symphony_elixir/extensions_test.exs
git commit -m "$(cat <<'EOF'
feat(presenter): board_payload/2 groups Linear issues by column

Joins issues with Orchestrator.snapshot.running and .retrying so each
card carries live agent_status. Linear fetch failure returns empty
columns plus an error envelope; UI gracefully degrades.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.3: Add `/api/v1/board` route and controller action

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Modify: `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`
- Test: `elixir/test/symphony_elixir/extensions_test.exs` (extend the `http server` test or add a new one)

- [ ] **Step 1.3.1: Write the failing test**

Append to `elixir/test/symphony_elixir/extensions_test.exs` near the existing `http server serves headless API` test (around line 536). Reuse its setup pattern:

```elixir
test "GET /api/v1/board returns board payload" do
  Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
  on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_module) end)

  Process.put({FakeLinearClient, :graphql_result}, nil)

  Process.put({FakeLinearClient, :fetch_issues_by_states}, fn _states ->
    {:ok,
     [
       %SymphonyElixir.Linear.Issue{
         id: "ix",
         identifier: "SODEV-100",
         title: "Test",
         state: "Todo",
         url: "u",
         priority: 1,
         assignee_id: nil,
         assignee_name: nil,
         assignee_display_name: nil,
         labels: [],
         has_pr_attachment: false
       }
     ]}
  end)

  {:ok, _orch} =
    SymphonyElixir.ExtensionsTest.StaticOrchestrator.start_link(
      name: SymphonyElixir.Orchestrator,
      snapshot: %{running: [], retrying: [], agent_totals: %{}, rate_limits: nil}
    )

  port = boot_test_endpoint()

  on_exit(fn -> stop_default_http_server() end)

  response = Req.get!("http://127.0.0.1:#{port}/api/v1/board")

  assert response.status == 200
  assert response.body["columns"] |> length() == 3

  todo_issues = response.body["columns"] |> Enum.find(&(&1["key"] == "todo")) |> Map.fetch!("issues")
  assert hd(todo_issues)["identifier"] == "SODEV-100"
end
```

(`boot_test_endpoint/0` is the existing helper used in extensions_test for the `http server` test — reuse it; if there is no such helper extracted, copy the relevant 5-10 line block from the existing `http server serves headless API` test that calls `HttpServer.start_link`.)

You also need to teach `FakeLinearClient` to honor `fetch_issues_by_states` overrides. Update its definition (around line 17-20):

```elixir
def fetch_issues_by_states(states) do
  send(self(), {:fetch_issues_by_states_called, states})

  case Process.get({__MODULE__, :fetch_issues_by_states}) do
    fun when is_function(fun, 1) -> fun.(states)
    _ -> {:ok, states}
  end
end
```

- [ ] **Step 1.3.2: Run test to verify it fails**

```bash
mix test test/symphony_elixir/extensions_test.exs -k "board"
```

Expected: FAIL — `404 not_found`.

- [ ] **Step 1.3.3: Add route**

In `elixir/lib/symphony_elixir_web/router.ex`, after the existing `get("/api/v1/state", ...)` line, add:

```elixir
    get("/api/v1/board", ObservabilityApiController, :board)
    match(:*, "/api/v1/board", ObservabilityApiController, :method_not_allowed)
```

The router should now read (excerpt):

```elixir
    get("/healthz", ObservabilityApiController, :healthz)
    match(:*, "/healthz", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/state", ObservabilityApiController, :state)
    get("/api/v1/board", ObservabilityApiController, :board)
    match(:*, "/api/v1/board", ObservabilityApiController, :method_not_allowed)
```

(Place the new lines BEFORE the `match(:*, "/", ...)` catch-all so they bind correctly.)

- [ ] **Step 1.3.4: Add controller action**

In `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`, after the existing `state/2`:

```elixir
  @spec board(Conn.t(), map()) :: Conn.t()
  def board(conn, _params) do
    json(conn, Presenter.board_payload(orchestrator(), snapshot_timeout_ms()))
  end
```

- [ ] **Step 1.3.5: Run test, verify pass**

```bash
mix test test/symphony_elixir/extensions_test.exs -k "board"
```

Expected: PASS.

- [ ] **Step 1.3.6: Commit**

```bash
git add elixir/lib/symphony_elixir_web/router.ex elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex elixir/test/symphony_elixir/extensions_test.exs
git commit -m "$(cat <<'EOF'
feat(api): expose GET /api/v1/board for kanban view

Returns Linear issues grouped into 3 columns (todo, in_progress, done)
with agent_status joined from Orchestrator.snapshot. Single endpoint;
SSE stream (next commit) only emits invalidation pings.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.4: Add `/api/v1/stream` SSE endpoint

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Modify: `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex` (add `stream/2`)
- Test: `elixir/test/symphony_elixir/extensions_test.exs` (add an SSE smoke test)

- [ ] **Step 1.4.1: Write the failing test**

```elixir
test "GET /api/v1/stream emits board_updated SSE on PubSub broadcast" do
  port = boot_test_endpoint()

  on_exit(fn -> stop_default_http_server() end)

  parent = self()

  spawn_link(fn ->
    Req.get!("http://127.0.0.1:#{port}/api/v1/stream",
      receive_timeout: 2_000,
      into: fn {:data, chunk}, acc ->
        send(parent, {:sse_chunk, chunk})
        {:cont, acc}
      end
    )
  end)

  # Allow SSE handshake to subscribe
  Process.sleep(100)

  assert :ok = SymphonyElixirWeb.ObservabilityPubSub.broadcast_update()

  assert_receive {:sse_chunk, chunk}, 1_500
  assert chunk =~ "event: board_updated"
end
```

- [ ] **Step 1.4.2: Run test to verify it fails**

```bash
mix test test/symphony_elixir/extensions_test.exs -k "stream"
```

Expected: FAIL — 404.

- [ ] **Step 1.4.3: Add route**

In `router.ex`, alongside the board route:

```elixir
    get("/api/v1/stream", ObservabilityApiController, :stream)
    match(:*, "/api/v1/stream", ObservabilityApiController, :method_not_allowed)
```

- [ ] **Step 1.4.4: Add controller action**

In `observability_api_controller.ex`:

```elixir
  alias SymphonyElixirWeb.ObservabilityPubSub

  @spec stream(Conn.t(), map()) :: Conn.t()
  def stream(conn, _params) do
    :ok = ObservabilityPubSub.subscribe()

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    sse_loop(conn)
  end

  defp sse_loop(conn) do
    receive do
      :observability_updated ->
        case Plug.Conn.chunk(conn, "event: board_updated\ndata: {}\n\n") do
          {:ok, conn} -> sse_loop(conn)
          {:error, _closed} -> conn
        end
    after
      15_000 ->
        case Plug.Conn.chunk(conn, ":heartbeat\n\n") do
          {:ok, conn} -> sse_loop(conn)
          {:error, _closed} -> conn
        end
    end
  end
```

- [ ] **Step 1.4.5: Run test, verify pass**

```bash
mix test test/symphony_elixir/extensions_test.exs -k "stream"
```

Expected: PASS.

- [ ] **Step 1.4.6: Commit**

```bash
git add elixir/lib/symphony_elixir_web/router.ex elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex elixir/test/symphony_elixir/extensions_test.exs
git commit -m "$(cat <<'EOF'
feat(api): SSE stream at /api/v1/stream pushes board_updated events

Subscribes to ObservabilityPubSub and forwards every dashboard tick as
an SSE event. Heartbeat every 15s keeps the connection warm through
proxies. UI re-fetches /api/v1/board on each event.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.5: Add CORS plug for `/api/v1/*`

**Files:**
- Create: `elixir/lib/symphony_elixir_web/plugs/cors.ex`
- Modify: `elixir/lib/symphony_elixir_web/endpoint.ex` (insert plug before Router)
- Test: `elixir/test/symphony_elixir/extensions_test.exs` (add CORS preflight test)

- [ ] **Step 1.5.1: Write the failing test**

```elixir
test "OPTIONS /api/v1/board returns 204 with CORS headers when origin is localhost:3000" do
  port = boot_test_endpoint()

  on_exit(fn -> stop_default_http_server() end)

  response =
    Req.request!(
      method: :options,
      url: "http://127.0.0.1:#{port}/api/v1/board",
      headers: [
        {"origin", "http://localhost:3000"},
        {"access-control-request-method", "GET"}
      ]
    )

  assert response.status == 204
  assert response.headers["access-control-allow-origin"] == ["http://localhost:3000"]
  assert "GET" in (response.headers["access-control-allow-methods"] |> List.wrap() |> Enum.flat_map(&String.split(&1, ", ")))
end

test "GET /api/v1/board includes CORS headers when origin is localhost:3000" do
  Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
  on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_module) end)

  Process.put({FakeLinearClient, :fetch_issues_by_states}, fn _ -> {:ok, []} end)

  {:ok, _orch} =
    SymphonyElixir.ExtensionsTest.StaticOrchestrator.start_link(
      name: SymphonyElixir.Orchestrator,
      snapshot: %{running: [], retrying: [], agent_totals: %{}, rate_limits: nil}
    )

  port = boot_test_endpoint()
  on_exit(fn -> stop_default_http_server() end)

  response =
    Req.get!("http://127.0.0.1:#{port}/api/v1/board",
      headers: [{"origin", "http://localhost:3000"}]
    )

  assert response.status == 200
  assert response.headers["access-control-allow-origin"] == ["http://localhost:3000"]
end
```

- [ ] **Step 1.5.2: Run tests to verify they fail**

```bash
mix test test/symphony_elixir/extensions_test.exs -k "CORS"
```

Expected: FAIL.

- [ ] **Step 1.5.3: Create the CORS plug**

`elixir/lib/symphony_elixir_web/plugs/cors.ex`:

```elixir
defmodule SymphonyElixirWeb.Plugs.CORS do
  @moduledoc """
  Minimal CORS plug for the observability API.

  Responds to preflight `OPTIONS /api/v1/*` with 204 and applies the
  standard headers to API responses when the request origin matches the
  configured allow-list (`http://localhost:3000` by default).
  """

  import Plug.Conn

  @default_origins ["http://localhost:3000"]

  def init(opts), do: Keyword.put_new(opts, :origins, @default_origins)

  def call(%Plug.Conn{path_info: ["api", "v1" | _]} = conn, opts) do
    origins = Keyword.fetch!(opts, :origins)
    origin = get_req_header(conn, "origin") |> List.first()

    if origin in origins do
      conn = put_cors_headers(conn, origin)

      case conn.method do
        "OPTIONS" -> conn |> send_resp(204, "") |> halt()
        _ -> conn
      end
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  defp put_cors_headers(conn, origin) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-methods", "GET, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type, accept")
    |> put_resp_header("vary", "origin")
  end
end
```

- [ ] **Step 1.5.4: Wire it into the endpoint**

In `elixir/lib/symphony_elixir_web/endpoint.ex`, insert the plug before `SymphonyElixirWeb.Router`:

```elixir
defmodule SymphonyElixirWeb.Endpoint do
  @moduledoc """
  Phoenix endpoint for Symphony's headless observability JSON API.
  """

  use Phoenix.Endpoint, otp_app: :symphony_elixir

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(SymphonyElixirWeb.Plugs.CORS)
  plug(SymphonyElixirWeb.Router)
end
```

- [ ] **Step 1.5.5: Run tests, verify pass**

```bash
mix test test/symphony_elixir/extensions_test.exs -k "CORS"
```

Expected: 2 PASS.

- [ ] **Step 1.5.6: Commit**

```bash
git add elixir/lib/symphony_elixir_web/plugs/cors.ex elixir/lib/symphony_elixir_web/endpoint.ex elixir/test/symphony_elixir/extensions_test.exs
git commit -m "$(cat <<'EOF'
feat(web): allow CORS from localhost:3000 on /api/v1/*

UI brick (symphony-ui) runs at localhost:3000 in dev. Plug responds to
preflight with 204 and tags every API response with the matched origin.
Non-API paths and non-matching origins pass through unchanged.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.6: Phase 1 verify gate

- [ ] **Step 1.6.1: Run lint**

```bash
cd /Users/vini/Developer/symphony/elixir
mix lint
```

Expected: clean (`specs.check` + `credo --strict`).

- [ ] **Step 1.6.2: Run full test suite**

```bash
mix test
```

Expected: all green.

- [ ] **Step 1.6.3: Run shadow gate**

```bash
SESSION=${CLAUDE_SESSION_ID:-default}
cd /Users/vini/Developer/symphony
scripts/shadow_run.sh "$(pwd)" "$SESSION"
```

Expected: rc=0 (PASS) or rc=2 (INCONCLUSIVE — pass through).

If rc=1, read `/tmp/devflow-shadow/$SESSION/shadow.log`, fix the failure, loop back to TDD on the failing task.

- [ ] **Step 1.6.4: Run review gate**

Invoke `pr-review-toolkit:review-pr` covering all 5 commits in Phase 1. Pass along the karpathy-rule check (over-abstraction) and the drive-by refactor check (the spec-mandated changes only).

If review flags issues, fix and re-commit before proceeding.

- [ ] **Step 1.6.5: Push**

```bash
git push
```

Branch is non-protected; auto-push allowed. `pre_push_gate` will revalidate.

---

## Phase 2 — `symphony-ui` repo scaffold

All work is in a NEW repo at `/Users/vini/Developer/symphony-ui`. No git remote yet (local-only per user direction).

### Task 2.1: Create the repo and Next.js scaffold

- [ ] **Step 2.1.1: Verify pnpm and Node availability**

```bash
which pnpm && pnpm --version
which node && node --version
```

Expected: pnpm >= 9, Node >= 20. If missing, install before continuing (`brew install pnpm node` or `corepack enable`).

- [ ] **Step 2.1.2: Create the repo**

```bash
mkdir -p /Users/vini/Developer/symphony-ui
cd /Users/vini/Developer/symphony-ui
git init -b main
```

- [ ] **Step 2.1.3: Scaffold Next.js**

```bash
cd /Users/vini/Developer/symphony-ui
pnpm create next-app@latest . \
  --typescript \
  --tailwind \
  --app \
  --eslint \
  --no-src-dir \
  --import-alias "@/*" \
  --use-pnpm \
  --turbopack
```

Expected: scaffolded `app/`, `package.json`, `tailwind.config.ts`, `tsconfig.json`. Confirm Next.js >= 15.

- [ ] **Step 2.1.4: First commit**

```bash
git add -A
git commit -m "chore: scaffold Next.js 15 + TS + Tailwind via create-next-app"
```

---

### Task 2.2: Initialize shadcn/ui

- [ ] **Step 2.2.1: Run shadcn init**

```bash
cd /Users/vini/Developer/symphony-ui
pnpm dlx shadcn@latest init -d
```

Pick: TypeScript, default style, slate base color, CSS variables on, app dir true, alias `@/components`, `@/lib/utils`. Use `-d` to take the maintainer-recommended defaults.

- [ ] **Step 2.2.2: Add base shadcn components**

```bash
pnpm dlx shadcn@latest add card badge scroll-area
```

Expected: `components/ui/card.tsx`, `components/ui/badge.tsx`, `components/ui/scroll-area.tsx`.

- [ ] **Step 2.2.3: Verify TypeScript still compiles**

```bash
pnpm tsc --noEmit
```

Expected: 0 errors.

- [ ] **Step 2.2.4: Commit**

```bash
git add -A
git commit -m "chore: init shadcn/ui with card, badge, scroll-area primitives"
```

---

### Task 2.3: Install runtime dependencies

- [ ] **Step 2.3.1: Install deps**

```bash
cd /Users/vini/Developer/symphony-ui
pnpm add @tanstack/react-query@^5 @microsoft/fetch-event-source@^2 motion@^12
```

- [ ] **Step 2.3.2: Install dev deps for testing**

```bash
pnpm add -D vitest@^2 @testing-library/react@^16 @testing-library/dom@^10 jsdom@^25 @vitejs/plugin-react@^4 @playwright/test@^1
pnpm playwright install chromium
```

- [ ] **Step 2.3.3: Add scripts to `package.json`**

Open `package.json`, replace the `"scripts"` block with:

```json
"scripts": {
  "dev": "next dev",
  "build": "next build",
  "start": "next start",
  "lint": "next lint",
  "typecheck": "tsc --noEmit",
  "test": "vitest run",
  "test:watch": "vitest",
  "test:e2e": "playwright test"
}
```

- [ ] **Step 2.3.4: Add Vitest config**

Create `/Users/vini/Developer/symphony-ui/vitest.config.ts`:

```typescript
import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import path from "node:path";

export default defineConfig({
  plugins: [react()],
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./vitest.setup.ts"],
  },
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "."),
    },
  },
});
```

Create `/Users/vini/Developer/symphony-ui/vitest.setup.ts`:

```typescript
import "@testing-library/dom/extend-expect";
```

- [ ] **Step 2.3.5: Add Playwright config**

Create `/Users/vini/Developer/symphony-ui/playwright.config.ts`:

```typescript
import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  use: { baseURL: "http://localhost:3000" },
  webServer: {
    command: "pnpm dev",
    url: "http://localhost:3000",
    reuseExistingServer: !process.env.CI,
    timeout: 60_000,
  },
});
```

- [ ] **Step 2.3.6: Verify build still works**

```bash
pnpm typecheck
pnpm build
```

Expected: 0 errors, build succeeds.

- [ ] **Step 2.3.7: Commit**

```bash
git add -A
git commit -m "chore: add TanStack Query, fetch-event-source, motion, Vitest, Playwright"
```

---

## Phase 3 — UI implementation

### Task 3.1: Frontend Gate

- [ ] **Step 3.1.1: Invoke frontend-design skill**

Brief: "Symphony UI MVP — read-only kanban view (3 columns: Todo / In Progress / Done) with active-card variant showing progress ring + last_event line + turn count. Dark theme matching brainstorming mockups (`bg #0d1117`, card `#161b22`, running border `#58a6ff`). Need polish review on: column header weight + spacing, card density, focus states for keyboard nav, motion easing for column transitions."

Apply any concrete corrections to the component code in tasks 3.5–3.8 before continuing.

---

### Task 3.2: Define API contract types (`lib/types.ts`)

**Files:**
- Create: `lib/types.ts`

- [ ] **Step 3.2.1: Write the file**

`/Users/vini/Developer/symphony-ui/lib/types.ts`:

```typescript
export type AgentStatus =
  | {
      running: true;
      session_id: string;
      turn_count: number;
      last_event: string | null;
      started_at: string;
      last_event_at: string | null;
      tokens: { total_tokens: number };
    }
  | {
      running: false;
      retry_attempt: number;
      retry_reason: string | null;
    };

export interface Assignee {
  id: string;
  name: string | null;
  display_name: string | null;
}

export interface BoardIssue {
  id: string;
  identifier: string;
  title: string;
  url: string;
  state: string;
  priority: number | null;
  labels: string[];
  has_pr_attachment: boolean;
  assignee: Assignee | null;
  agent_status: AgentStatus | null;
}

export interface BoardColumn {
  key: "todo" | "in_progress" | "done";
  label: string;
  linear_states: string[];
  issues: BoardIssue[];
}

export interface BoardPayload {
  generated_at: string;
  columns: BoardColumn[];
  error?: { code: string; message: string };
}
```

- [ ] **Step 3.2.2: Verify**

```bash
pnpm tsc --noEmit
```

Expected: 0 errors.

---

### Task 3.3: Implement `lib/api.ts`

**Files:**
- Create: `lib/api.ts`
- Test: `__tests__/api.test.ts`

- [ ] **Step 3.3.1: Write the failing test**

`/Users/vini/Developer/symphony-ui/__tests__/api.test.ts`:

```typescript
import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { fetchBoard } from "@/lib/api";

describe("fetchBoard", () => {
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
    globalThis.fetch = vi.fn();
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it("requests /api/v1/board and returns JSON", async () => {
    const payload = { generated_at: "2026-04-30T20:00:00Z", columns: [] };

    (globalThis.fetch as unknown as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
      ok: true,
      json: async () => payload,
    });

    const result = await fetchBoard("http://api.test");

    expect(globalThis.fetch).toHaveBeenCalledWith("http://api.test/api/v1/board", expect.any(Object));
    expect(result).toEqual(payload);
  });

  it("throws when the response is not ok", async () => {
    (globalThis.fetch as unknown as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
      ok: false,
      status: 503,
    });

    await expect(fetchBoard("http://api.test")).rejects.toThrow(/503/);
  });
});
```

- [ ] **Step 3.3.2: Run, verify FAIL**

```bash
pnpm test __tests__/api.test.ts
```

Expected: FAIL (module not found).

- [ ] **Step 3.3.3: Write the implementation**

`/Users/vini/Developer/symphony-ui/lib/api.ts`:

```typescript
import type { BoardPayload } from "@/lib/types";

export async function fetchBoard(apiBase: string): Promise<BoardPayload> {
  const response = await fetch(`${apiBase}/api/v1/board`, {
    headers: { accept: "application/json" },
  });

  if (!response.ok) {
    throw new Error(`Symphony API responded ${response.status}`);
  }

  return (await response.json()) as BoardPayload;
}
```

- [ ] **Step 3.3.4: Run, verify PASS**

```bash
pnpm test __tests__/api.test.ts
```

Expected: 2 PASS.

---

### Task 3.4: Implement `lib/stream.ts` SSE hook

**Files:**
- Create: `lib/stream.ts`

This is a thin React hook around `@microsoft/fetch-event-source`. No unit test in v0 — covered by the Playwright e2e in Task 3.13.

- [ ] **Step 3.4.1: Write the file**

`/Users/vini/Developer/symphony-ui/lib/stream.ts`:

```typescript
"use client";

import { fetchEventSource } from "@microsoft/fetch-event-source";
import { useEffect } from "react";

export function useBoardStream(apiBase: string, onUpdate: () => void): void {
  useEffect(() => {
    const controller = new AbortController();

    void fetchEventSource(`${apiBase}/api/v1/stream`, {
      signal: controller.signal,
      headers: { accept: "text/event-stream" },
      onmessage(event) {
        if (event.event === "board_updated") {
          onUpdate();
        }
      },
      onerror(error) {
        console.warn("Symphony SSE error", error);
        return 5_000;
      },
      openWhenHidden: true,
    });

    return () => controller.abort();
  }, [apiBase, onUpdate]);
}
```

- [ ] **Step 3.4.2: Verify typecheck**

```bash
pnpm tsc --noEmit
```

Expected: 0 errors.

---

### Task 3.5: `components/issue-card.tsx` (idle card)

**Files:**
- Create: `components/issue-card.tsx`
- Test: `__tests__/issue-card.test.tsx`

- [ ] **Step 3.5.1: Write the failing test**

`/Users/vini/Developer/symphony-ui/__tests__/issue-card.test.tsx`:

```typescript
import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { IssueCard } from "@/components/issue-card";
import type { BoardIssue } from "@/lib/types";

const baseIssue: BoardIssue = {
  id: "1",
  identifier: "SODEV-1",
  title: "Add robots.txt",
  url: "https://linear.app/x",
  state: "Todo",
  priority: 2,
  labels: ["seo"],
  has_pr_attachment: false,
  assignee: { id: "a1", name: "Vini Freitas", display_name: "vini" },
  agent_status: null,
};

describe("<IssueCard>", () => {
  it("renders identifier, title, and assignee initials", () => {
    render(<IssueCard issue={baseIssue} />);
    expect(screen.getByText("SODEV-1")).toBeInTheDocument();
    expect(screen.getByText("Add robots.txt")).toBeInTheDocument();
    expect(screen.getByText("VF")).toBeInTheDocument();
  });

  it("renders a PR badge when has_pr_attachment is true", () => {
    render(<IssueCard issue={{ ...baseIssue, has_pr_attachment: true }} />);
    expect(screen.getByLabelText("PR attached")).toBeInTheDocument();
  });

  it("renders nothing for assignee when null", () => {
    render(<IssueCard issue={{ ...baseIssue, assignee: null }} />);
    expect(screen.queryByText("VF")).not.toBeInTheDocument();
  });
});
```

- [ ] **Step 3.5.2: Run, verify FAIL**

```bash
pnpm test __tests__/issue-card.test.tsx
```

- [ ] **Step 3.5.3: Implement**

`/Users/vini/Developer/symphony-ui/components/issue-card.tsx`:

```typescript
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import type { BoardIssue } from "@/lib/types";

function initials(name: string | null | undefined): string {
  if (!name) return "";
  return name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0]?.toUpperCase() ?? "")
    .join("");
}

export function IssueCard({ issue }: { issue: BoardIssue }) {
  return (
    <Card className="border-zinc-700 bg-zinc-900 transition-colors hover:border-zinc-500">
      <CardContent className="p-3">
        <div className="flex items-center justify-between text-xs text-zinc-400">
          <span>{issue.identifier}</span>
          {issue.has_pr_attachment && (
            <span aria-label="PR attached" title="PR attached" className="text-emerald-400">
              ●
            </span>
          )}
        </div>
        <div className="mt-1 text-sm font-medium leading-tight text-zinc-100">{issue.title}</div>
        <div className="mt-2 flex items-center justify-between text-[11px] text-zinc-500">
          <div className="flex flex-wrap gap-1">
            {issue.labels.map((label) => (
              <Badge key={label} variant="outline" className="border-zinc-700 text-[10px]">
                {label}
              </Badge>
            ))}
          </div>
          {issue.assignee?.name && (
            <span className="font-mono text-zinc-300">{initials(issue.assignee.name)}</span>
          )}
        </div>
      </CardContent>
    </Card>
  );
}
```

- [ ] **Step 3.5.4: Run, verify PASS**

```bash
pnpm test __tests__/issue-card.test.tsx
```

Expected: 3 PASS.

---

### Task 3.6: `components/running-card.tsx` (active variant B)

**Files:**
- Create: `components/running-card.tsx`
- Test: `__tests__/running-card.test.tsx`

- [ ] **Step 3.6.1: Write the failing test**

```typescript
import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { RunningCard } from "@/components/running-card";
import type { BoardIssue } from "@/lib/types";

const runningIssue: BoardIssue = {
  id: "2",
  identifier: "SODEV-789",
  title: "Add robots.txt",
  url: "u",
  state: "In Progress",
  priority: 1,
  labels: [],
  has_pr_attachment: false,
  assignee: { id: "a", name: "Vini", display_name: "vini" },
  agent_status: {
    running: true,
    session_id: "s1",
    turn_count: 7,
    last_event: "writing test for /robots.txt",
    started_at: "2026-04-30T18:55:00Z",
    last_event_at: "2026-04-30T19:00:00Z",
    tokens: { total_tokens: 2400 },
  },
};

describe("<RunningCard>", () => {
  it("renders the last_event line and turn count", () => {
    render(<RunningCard issue={runningIssue} />);
    expect(screen.getByText(/writing test/)).toBeInTheDocument();
    expect(screen.getByText(/turn 7/)).toBeInTheDocument();
  });

  it("falls back to identifier when last_event is null", () => {
    const issue = {
      ...runningIssue,
      agent_status: { ...runningIssue.agent_status!, last_event: null },
    };
    render(<RunningCard issue={issue} />);
    expect(screen.getByText(/working/i)).toBeInTheDocument();
  });
});
```

Save as `/Users/vini/Developer/symphony-ui/__tests__/running-card.test.tsx`.

- [ ] **Step 3.6.2: Run, verify FAIL**

```bash
pnpm test __tests__/running-card.test.tsx
```

- [ ] **Step 3.6.3: Implement**

`/Users/vini/Developer/symphony-ui/components/running-card.tsx`:

```typescript
import { Card, CardContent } from "@/components/ui/card";
import type { BoardIssue } from "@/lib/types";

export function RunningCard({ issue }: { issue: BoardIssue }) {
  if (!issue.agent_status?.running) {
    return null;
  }

  const status = issue.agent_status;
  const lastEvent = status.last_event ?? "working...";

  return (
    <Card className="relative overflow-hidden border-2 border-blue-500 bg-zinc-900 shadow-[0_0_16px_rgba(88,166,255,0.3)]">
      <CardContent className="p-3">
        <div className="flex items-center justify-between text-xs text-blue-400">
          <span>{issue.identifier}</span>
          <ProgressRing />
        </div>
        <div className="mt-1 text-sm font-medium leading-tight text-zinc-100">{issue.title}</div>
        <div className="mt-2 rounded border-l-2 border-blue-500 bg-blue-500/10 px-2 py-1 font-mono text-[11px] leading-snug text-blue-200">
          ▸ {lastEvent}
        </div>
        <div className="mt-2 flex items-center justify-between text-[11px] text-zinc-500">
          <span className="font-mono text-zinc-400">
            {issue.assignee?.display_name ? `@${issue.assignee.display_name}` : ""}
          </span>
          <span className="font-mono text-zinc-400">turn {status.turn_count}</span>
        </div>
      </CardContent>
    </Card>
  );
}

function ProgressRing() {
  return (
    <svg width="20" height="20" viewBox="0 0 20 20" aria-hidden="true">
      <circle cx="10" cy="10" r="8" fill="none" stroke="rgb(33,38,45)" strokeWidth="2" />
      <circle
        cx="10"
        cy="10"
        r="8"
        fill="none"
        stroke="rgb(88,166,255)"
        strokeWidth="2"
        strokeDasharray="50.27"
        strokeDashoffset="35"
        className="origin-center animate-spin"
        style={{ animationDuration: "1.5s" }}
      />
    </svg>
  );
}
```

- [ ] **Step 3.6.4: Run, verify PASS**

```bash
pnpm test __tests__/running-card.test.tsx
```

Expected: 2 PASS.

---

### Task 3.7: `components/column.tsx`

**Files:**
- Create: `components/column.tsx`
- Test: `__tests__/column.test.tsx`

- [ ] **Step 3.7.1: Write the failing test**

```typescript
import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { Column } from "@/components/column";
import type { BoardColumn } from "@/lib/types";

const sample: BoardColumn = {
  key: "in_progress",
  label: "In Progress",
  linear_states: ["In Progress"],
  issues: [
    {
      id: "1", identifier: "SODEV-1", title: "T1", url: "u",
      state: "In Progress", priority: null, labels: [],
      has_pr_attachment: false, assignee: null, agent_status: null,
    },
    {
      id: "2", identifier: "SODEV-2", title: "T2", url: "u",
      state: "In Progress", priority: null, labels: [],
      has_pr_attachment: false, assignee: null, agent_status: null,
    },
  ],
};

describe("<Column>", () => {
  it("renders header label and issue count", () => {
    render(<Column column={sample} />);
    expect(screen.getByText("In Progress")).toBeInTheDocument();
    expect(screen.getByText("2")).toBeInTheDocument();
  });

  it("renders one card per issue", () => {
    render(<Column column={sample} />);
    expect(screen.getAllByText(/SODEV-/)).toHaveLength(2);
  });
});
```

Save as `/Users/vini/Developer/symphony-ui/__tests__/column.test.tsx`.

- [ ] **Step 3.7.2: Run, FAIL**

```bash
pnpm test __tests__/column.test.tsx
```

- [ ] **Step 3.7.3: Implement**

`/Users/vini/Developer/symphony-ui/components/column.tsx`:

```typescript
"use client";

import { motion } from "motion/react";
import { ScrollArea } from "@/components/ui/scroll-area";
import { IssueCard } from "@/components/issue-card";
import { RunningCard } from "@/components/running-card";
import type { BoardColumn } from "@/lib/types";

const COLUMN_ACCENT: Record<BoardColumn["key"], string> = {
  todo: "text-zinc-400",
  in_progress: "text-blue-400",
  done: "text-emerald-400",
};

export function Column({ column }: { column: BoardColumn }) {
  return (
    <div className="flex h-full min-w-[280px] flex-1 flex-col rounded-lg bg-zinc-950/40 p-3">
      <div className="mb-3 flex items-center justify-between">
        <span className={`text-xs font-semibold uppercase tracking-wide ${COLUMN_ACCENT[column.key]}`}>
          {column.label}
        </span>
        <span className="text-xs text-zinc-500">{column.issues.length}</span>
      </div>
      <ScrollArea className="flex-1">
        <div className="flex flex-col gap-2">
          {column.issues.map((issue) => (
            <motion.div
              key={issue.id}
              layout
              layoutId={issue.id}
              transition={{ type: "spring", duration: 0.4, bounce: 0.15 }}
            >
              {issue.agent_status?.running ? (
                <RunningCard issue={issue} />
              ) : (
                <IssueCard issue={issue} />
              )}
            </motion.div>
          ))}
          {column.issues.length === 0 && (
            <div className="py-8 text-center text-xs text-zinc-600">—</div>
          )}
        </div>
      </ScrollArea>
    </div>
  );
}
```

- [ ] **Step 3.7.4: Run, PASS**

```bash
pnpm test __tests__/column.test.tsx
```

Expected: 2 PASS.

---

### Task 3.8: `components/board.tsx`

**Files:**
- Create: `components/board.tsx`
- Test: `__tests__/board.test.tsx`

- [ ] **Step 3.8.1: Write the failing test**

```typescript
import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Board } from "@/components/board";
import type { BoardPayload } from "@/lib/types";

vi.mock("@/lib/api", () => ({
  fetchBoard: vi.fn(),
}));

vi.mock("@/lib/stream", () => ({
  useBoardStream: vi.fn(),
}));

import { fetchBoard } from "@/lib/api";

const samplePayload: BoardPayload = {
  generated_at: "2026-04-30T20:00:00Z",
  columns: [
    { key: "todo", label: "Todo", linear_states: ["Todo"], issues: [] },
    {
      key: "in_progress",
      label: "In Progress",
      linear_states: ["In Progress"],
      issues: [
        {
          id: "x", identifier: "SODEV-X", title: "Active", url: "u",
          state: "In Progress", priority: null, labels: [],
          has_pr_attachment: false, assignee: null, agent_status: null,
        },
      ],
    },
    { key: "done", label: "Done", linear_states: ["Done"], issues: [] },
  ],
};

describe("<Board>", () => {
  it("renders 3 columns from the API payload", async () => {
    (fetchBoard as ReturnType<typeof vi.fn>).mockResolvedValue(samplePayload);

    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });

    render(
      <QueryClientProvider client={client}>
        <Board apiBase="http://api.test" />
      </QueryClientProvider>
    );

    expect(await screen.findByText("Todo")).toBeInTheDocument();
    expect(screen.getByText("In Progress")).toBeInTheDocument();
    expect(screen.getByText("Done")).toBeInTheDocument();
    expect(await screen.findByText("Active")).toBeInTheDocument();
  });
});
```

Save as `/Users/vini/Developer/symphony-ui/__tests__/board.test.tsx`.

- [ ] **Step 3.8.2: Run, FAIL**

```bash
pnpm test __tests__/board.test.tsx
```

- [ ] **Step 3.8.3: Implement**

`/Users/vini/Developer/symphony-ui/components/board.tsx`:

```typescript
"use client";

import { useCallback } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { fetchBoard } from "@/lib/api";
import { useBoardStream } from "@/lib/stream";
import { Column } from "@/components/column";
import type { BoardPayload } from "@/lib/types";

export function Board({ apiBase }: { apiBase: string }) {
  const queryClient = useQueryClient();
  const { data, isLoading, error } = useQuery<BoardPayload>({
    queryKey: ["board", apiBase],
    queryFn: () => fetchBoard(apiBase),
    refetchOnWindowFocus: true,
  });

  const onStreamUpdate = useCallback(() => {
    void queryClient.invalidateQueries({ queryKey: ["board", apiBase] });
  }, [queryClient, apiBase]);

  useBoardStream(apiBase, onStreamUpdate);

  if (isLoading) {
    return <div className="p-6 text-zinc-500">Loading board…</div>;
  }

  if (error) {
    return <div className="p-6 text-red-400">Symphony backend unreachable.</div>;
  }

  if (!data) return null;

  return (
    <div className="flex h-screen w-full gap-3 bg-zinc-950 p-4">
      {data.columns.map((column) => (
        <Column key={column.key} column={column} />
      ))}
    </div>
  );
}
```

- [ ] **Step 3.8.4: Run, PASS**

```bash
pnpm test __tests__/board.test.tsx
```

Expected: 1 PASS.

---

### Task 3.9: Wire `app/page.tsx` and `app/layout.tsx`

**Files:**
- Modify: `app/layout.tsx` (set body bg + dark)
- Replace: `app/page.tsx`
- Create: `app/providers.tsx`

- [ ] **Step 3.9.1: Create the QueryClientProvider wrapper**

`/Users/vini/Developer/symphony-ui/app/providers.tsx`:

```typescript
"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState, type PropsWithChildren } from "react";

export function Providers({ children }: PropsWithChildren) {
  const [client] = useState(
    () =>
      new QueryClient({
        defaultOptions: { queries: { staleTime: 0, refetchOnWindowFocus: true } },
      })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}
```

- [ ] **Step 3.9.2: Replace `app/page.tsx`**

```typescript
import { Board } from "@/components/board";
import { Providers } from "@/app/providers";

const API_BASE = process.env.NEXT_PUBLIC_SYMPHONY_API ?? "http://localhost:4000";

export default function Page() {
  return (
    <Providers>
      <Board apiBase={API_BASE} />
    </Providers>
  );
}
```

- [ ] **Step 3.9.3: Update `app/layout.tsx`**

Replace the `<body>` className to set the dark theme:

```typescript
<body className="min-h-screen bg-zinc-950 text-zinc-100 antialiased">{children}</body>
```

- [ ] **Step 3.9.4: Add a `.env.local.example` for clarity**

`/Users/vini/Developer/symphony-ui/.env.local.example`:

```
NEXT_PUBLIC_SYMPHONY_API=http://localhost:4000
```

- [ ] **Step 3.9.5: Verify typecheck + build**

```bash
pnpm typecheck
pnpm build
```

Expected: 0 errors, build succeeds.

- [ ] **Step 3.9.6: Commit**

```bash
git add -A
git commit -m "feat(ui): kanban board reads /api/v1/board, refreshes on SSE event"
```

---

### Task 3.10: Playwright smoke test

**Files:**
- Create: `e2e/board.spec.ts`

- [ ] **Step 3.10.1: Write the test**

`/Users/vini/Developer/symphony-ui/e2e/board.spec.ts`:

```typescript
import { test, expect } from "@playwright/test";

test("board renders 3 columns when API responds", async ({ page }) => {
  await page.route("**/api/v1/board", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        generated_at: "2026-04-30T20:00:00Z",
        columns: [
          { key: "todo", label: "Todo", linear_states: ["Todo"], issues: [] },
          {
            key: "in_progress",
            label: "In Progress",
            linear_states: ["In Progress"],
            issues: [
              {
                id: "1",
                identifier: "SODEV-1",
                title: "Sample Active Task",
                url: "u",
                state: "In Progress",
                priority: 1,
                labels: ["seo"],
                has_pr_attachment: false,
                assignee: { id: "a", name: "Vini Freitas", display_name: "vini" },
                agent_status: {
                  running: true,
                  session_id: "s",
                  turn_count: 5,
                  last_event: "writing test",
                  started_at: "2026-04-30T19:00:00Z",
                  last_event_at: "2026-04-30T19:05:00Z",
                  tokens: { total_tokens: 1000 },
                },
              },
            ],
          },
          { key: "done", label: "Done", linear_states: ["Done"], issues: [] },
        ],
      }),
    });
  });

  await page.route("**/api/v1/stream", async (route) => {
    await route.fulfill({ status: 204 });
  });

  await page.goto("/");

  await expect(page.getByText("Todo")).toBeVisible();
  await expect(page.getByText("In Progress")).toBeVisible();
  await expect(page.getByText("Done")).toBeVisible();
  await expect(page.getByText("Sample Active Task")).toBeVisible();
  await expect(page.getByText(/turn 5/)).toBeVisible();
});
```

- [ ] **Step 3.10.2: Run the e2e**

```bash
pnpm test:e2e
```

Expected: 1 PASS.

- [ ] **Step 3.10.3: Commit**

```bash
git add -A
git commit -m "test(ui): playwright smoke covering kanban + active card"
```

---

### Task 3.11: Phase 3 verify gate

- [ ] **Step 3.11.1: Lint, typecheck, unit, build**

```bash
cd /Users/vini/Developer/symphony-ui
pnpm lint
pnpm typecheck
pnpm test
pnpm build
```

Expected: all green.

- [ ] **Step 3.11.2: Review gate**

Invoke `pr-review-toolkit:review-pr` against the entire `symphony-ui` repo (commits since `git init`). Same karpathy + drive-by checks.

If review flags issues, fix and re-commit before proceeding.

---

## Phase 4 — Wire-up + manual smoke

### Task 4.1: Boot Symphony locally

- [ ] **Step 4.1.1: Source secrets**

```bash
source ~/.symphony/launch.sh
echo "$LINEAR_API_KEY" | head -c 8 ; echo " ... ok"
```

Expected: prefix of the API key prints. (Per memory `reference_symphony_launch.md`.)

- [ ] **Step 4.1.2: Boot the orchestrator**

```bash
cd /Users/vini/Developer/symphony/elixir
mix run --no-halt
```

Leave running. Confirm `/api/v1/board` responds:

```bash
curl -s http://localhost:4000/api/v1/board | head -c 200
```

Expected: JSON with `generated_at` and 3 columns.

---

### Task 4.2: Boot symphony-ui

- [ ] **Step 4.2.1: Boot dev server**

In a new terminal:

```bash
cd /Users/vini/Developer/symphony-ui
pnpm dev
```

Expected: Next.js dev server on `http://localhost:3000`.

- [ ] **Step 4.2.2: Open browser**

Open `http://localhost:3000`. Expected: 3 columns rendered with real schoolsout Linear issues distributed across them.

---

### Task 4.3: Manual smoke checklist

- [ ] **Step 4.3.1: Verify column composition**

Verify each issue lands in the correct column based on its Linear state:
- "Todo" / "Backlog" → left column
- "In Progress" / "In Review" → middle column
- "Done" / "Cancelled" / "Duplicate" → right column

- [ ] **Step 4.3.2: Verify active card variant**

If Symphony is currently running an agent (or you trigger one via `curl -X POST http://localhost:4000/api/v1/refresh`), verify the corresponding card flips to the running variant within ~3s of the next orchestrator tick. Confirm:
- Border is blue.
- Progress ring spins.
- "▸ {last_event}" line displays.
- Bottom-right shows "turn N".

- [ ] **Step 4.3.3: Verify column transition animation**

Move a Linear issue manually (in the Linear web UI) from "Todo" to "In Progress". On the next orchestrator poll tick (default 5min, or trigger via `/api/v1/refresh`), verify the card animates from the left column into the middle column smoothly.

- [ ] **Step 4.3.4: Verify SSE-triggered refetch**

In a third terminal, run:

```bash
curl -N http://localhost:4000/api/v1/stream | head
```

Expected: heartbeat lines. When Symphony ticks, expect `event: board_updated`. The browser should refetch within milliseconds.

---

### Task 4.4: Capture before/after screenshot

- [ ] **Step 4.4.1: Take screenshot**

Use macOS shortcut Cmd+Shift+4 to capture the board. Save to `/Users/vini/Developer/symphony/docs/media/symphony-ui-mvp-v0.png`. Create the directory if missing:

```bash
mkdir -p /Users/vini/Developer/symphony/docs/media
```

- [ ] **Step 4.4.2: Commit the screenshot to symphony repo**

```bash
cd /Users/vini/Developer/symphony
git add docs/media/symphony-ui-mvp-v0.png
git commit -m "docs(media): capture symphony-ui MVP wireframe v0"
```

---

### Task 4.5: Final commits + push

- [ ] **Step 4.5.1: Push symphony backend**

```bash
cd /Users/vini/Developer/symphony
git push
```

Branch `feature/codex-to-claude-migration` is non-protected. Auto-push allowed.

- [ ] **Step 4.5.2: symphony-ui repo final state**

The symphony-ui repo has no remote per user direction. Leave as local-only:

```bash
cd /Users/vini/Developer/symphony-ui
git log --oneline | head
```

Expected: linear history of feature commits. If user later attaches a remote (`gh repo create symphony-ui --source=. --push`), they can push at that point.

- [ ] **Step 4.5.3: Update active-spec state to COMPLETED**

```bash
echo '{"status":"COMPLETED","plan_path":"docs/plans/2026-04-30-symphony-ui-mvp-plan.md","started_at":1777584063}' \
  > ~/.claude/devflow/state/default/active-spec.json
```

- [ ] **Step 4.5.4: Mark TaskList completed**

Set tasks 8 and any open in-progress items to completed.

---

## Phase 5 — Memory hygiene (post-merge)

- [ ] **Step 5.1: Save UI wireframe outcome to auto-memory**

Add a new memory file under `~/.claude/projects/-Users-vini-Developer-symphony/memory/`:

`project_symphony_ui_mvp.md`:

```markdown
---
name: Symphony UI MVP shipped
description: Read-only kanban brick at ~/Developer/symphony-ui plugged into Symphony /api/v1/board + SSE; v0 shipped 2026-04-30.
type: project
---

Symphony gained a separate UI brick at `~/Developer/symphony-ui` (Next.js 15 + TS + shadcn/ui + Tailwind v4 + TanStack Query + framer-motion + fetch-event-source). It reads `/api/v1/board` (new) and refreshes on SSE events from `/api/v1/stream` (new) which proxies `ObservabilityPubSub`. Backend additions live in `feature/codex-to-claude-migration`. Eval and sandbox bricks deferred per design spec.

**Why:** non-technical reviewers (Juan, schoolsout team) needed to see agent activity without reading logs.
**How to apply:** when the user references "Symphony UI" or "the board", point to `~/Developer/symphony-ui`. When extending API surface, the contract types live in `lib/types.ts` of that repo + `Presenter.board_payload/2` in this repo.
```

Then add a one-liner entry to `MEMORY.md`:

```
- [Symphony UI MVP shipped](project_symphony_ui_mvp.md) — kanban brick at ~/Developer/symphony-ui reading /api/v1/board + SSE; eval/sandbox deferred
```

---

## Self-review

Spec coverage:
- Backend additions (Issue extension, board_payload, /api/v1/board, /api/v1/stream, CORS) — Phase 1, tasks 1.1–1.5. ✅
- UI scaffold (Next.js + Tailwind + shadcn) — Phase 2, tasks 2.1–2.3. ✅
- UI implementation (types, api, stream hook, IssueCard, RunningCard, Column, Board, page wiring) — Phase 3, tasks 3.2–3.9. ✅
- Tests (Vitest unit + Playwright smoke) — tasks 3.3, 3.5, 3.6, 3.7, 3.8, 3.10. ✅
- Manual smoke — Phase 4. ✅
- Verify / shadow / review gates — Phase 1.6, 3.11. ✅
- Auto-push on non-protected branch — 4.5.1. ✅
- Frontend Gate — 3.1. ✅
- Memory update — Phase 5. ✅

Out of spec by design: deploy pipeline, auth, eval brick, sandbox brick, multi-project — all listed in the design as deferred.

Type/signature consistency:
- Elixir: `Presenter.board_payload/2` and `/3` agree on shape returned. ✅
- TypeScript: `BoardPayload` ↔ Elixir JSON match (snake_case fields preserved). `agent_status` discriminated by `running: true|false`. ✅
- Test mocks reuse the canonical `BoardIssue` shape across all component tests. ✅

No placeholders. Every step has runnable commands or complete code.

End of plan.
