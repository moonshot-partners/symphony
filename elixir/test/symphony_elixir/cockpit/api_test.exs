defmodule SymphonyElixir.Cockpit.ApiTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias SymphonyElixir.Cockpit.Api

  @opts Api.init([])

  defp call(method, path, headers \\ []) do
    conn = conn(method, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Api.call(conn, @opts)
  end

  describe "routes" do
    test "GET /health returns ok" do
      conn = call(:get, "/health")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
    end

    test "GET /board returns the contract shape" do
      conn = call(:get, "/board")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "states")
      assert is_list(body["tickets"])
    end

    test "/board reads the ledger when SYMPHONY_RUNS_PATH points at a file" do
      path = Path.join(System.tmp_dir!(), "cockpit_runs_#{System.unique_integer([:positive])}.jsonl")
      File.write!(path, ~s({"ticket":"SODEV-X","turns":2}\n))
      System.put_env("SYMPHONY_RUNS_PATH", path)

      on_exit(fn ->
        System.delete_env("SYMPHONY_RUNS_PATH")
        File.rm(path)
      end)

      conn = call(:get, "/board")
      assert conn.status == 200
    end

    test "unknown routes return 404" do
      conn = call(:get, "/nope")
      assert conn.status == 404
    end
  end

  describe "GET /linear-asset/*path" do
    test "proxies a Linear upload, injecting auth, and streams the bytes back" do
      png = <<137, 80, 78, 71, 13, 10, 26, 10>>

      Application.put_env(:symphony_elixir, :linear_asset_fetcher, fn url ->
        send(self(), {:fetched, url})
        {:ok, %{body: png, content_type: "image/png"}}
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_asset_fetcher) end)

      conn = call(:get, "/linear-asset/ws-id/dir-id/file-id")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert conn.resp_body == png
      assert_received {:fetched, "https://uploads.linear.app/ws-id/dir-id/file-id"}
    end

    test "returns 404 when the upstream asset cannot be fetched" do
      Application.put_env(:symphony_elixir, :linear_asset_fetcher, fn _url -> {:error, :upstream} end)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_asset_fetcher) end)

      assert call(:get, "/linear-asset/ws-id/dir-id/missing").status == 404
    end
  end

  describe "GET /live" do
    test "serves the live agents from the orchestrator snapshot" do
      snapshot = %{
        running: [
          %{
            issue_id: "issue-1",
            identifier: "SODEV-956",
            state: "In Progress",
            worker_host: "hetzner-1",
            workspace_path: "/opt/symphony/work/issue-1",
            session_id: "sess-abc",
            agent_pid: self(),
            agent_input_tokens: 100,
            agent_output_tokens: 20,
            agent_total_tokens: 120,
            turn_count: 5,
            started_at: ~U[2026-06-02 12:00:00Z],
            last_agent_timestamp: ~U[2026-06-02 12:01:00Z],
            last_agent_message: "Running tests",
            last_agent_event: :tool_use,
            agent_cost_usd: 0.27,
            langfuse_trace_id: "trace-xyz",
            recent_events: [%{event: :tool_use, action: "Running tests", at: ~U[2026-06-02 12:01:00Z]}],
            runtime_seconds: 60
          }
        ],
        retrying: [],
        agent_totals: %{},
        rate_limits: nil,
        polling: %{checking?: false, next_poll_in_ms: 9_000, poll_interval_ms: 30_000}
      }

      Application.put_env(:symphony_elixir, :cockpit_snapshot_fn, fn -> snapshot end)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :cockpit_snapshot_fn) end)

      conn = call(:get, "/live")

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["available"] == true
      assert [agent] = body["agents"]
      assert agent["id"] == "SODEV-956"
      assert agent["turn"] == 5
      assert agent["lastAction"] == "Running tests"
      assert agent["costUsd"] == 0.27
      assert agent["traceUrl"] == "https://cloud.langfuse.com/trace/trace-xyz"

      assert agent["events"] == [
               %{"event" => "tool_use", "action" => "Running tests", "at" => "2026-06-02T12:01:00Z"}
             ]

      assert body["polling"]["nextPollInMs"] == 9_000
    end

    test "returns an unavailable payload when the orchestrator times out" do
      Application.put_env(:symphony_elixir, :cockpit_snapshot_fn, fn -> :timeout end)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :cockpit_snapshot_fn) end)

      conn = call(:get, "/live")

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["available"] == false
    end

    test "is gated by the bearer token like the other routes" do
      System.put_env("SYMPHONY_COCKPIT_API_TOKEN", "secret")
      Application.put_env(:symphony_elixir, :cockpit_snapshot_fn, fn -> :unavailable end)

      on_exit(fn ->
        System.delete_env("SYMPHONY_COCKPIT_API_TOKEN")
        Application.delete_env(:symphony_elixir, :cockpit_snapshot_fn)
      end)

      assert call(:get, "/live").status == 401
      assert call(:get, "/live", [{"authorization", "Bearer secret"}]).status == 200
    end
  end

  describe "operations" do
    test "POST /refresh invalidates and queues an orchestrator refresh" do
      Application.put_env(:symphony_elixir, :cockpit_refresh_fn, fn ->
        %{queued: true, coalesced: false, operations: ["poll", "reconcile"]}
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :cockpit_refresh_fn) end)

      conn = call(:post, "/refresh")

      assert conn.status == 202

      assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
               Jason.decode!(conn.resp_body)
    end

    test "POST /refresh returns 503 when the orchestrator is unavailable" do
      Application.put_env(:symphony_elixir, :cockpit_refresh_fn, fn -> :unavailable end)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :cockpit_refresh_fn) end)

      conn = call(:post, "/refresh")

      assert conn.status == 503
      assert Jason.decode!(conn.resp_body) == %{"error" => "orchestrator_unavailable"}
    end

    test "POST /runs/:issue_id/stop stops a running issue" do
      Application.put_env(:symphony_elixir, :cockpit_stop_run_fn, fn issue_id ->
        send(self(), {:stop_run, issue_id})
        {:ok, %{stopped: true, issue_id: issue_id, identifier: "SODEV-956"}}
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :cockpit_stop_run_fn) end)

      conn = call(:post, "/runs/uuid-956/stop")

      assert conn.status == 200

      assert Jason.decode!(conn.resp_body) == %{
               "stopped" => true,
               "issue_id" => "uuid-956",
               "identifier" => "SODEV-956"
             }

      assert_received {:stop_run, "uuid-956"}
    end

    test "POST /runs/:issue_id/stop returns 404 when the issue is not running" do
      Application.put_env(:symphony_elixir, :cockpit_stop_run_fn, fn _issue_id -> {:error, :not_running} end)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :cockpit_stop_run_fn) end)

      conn = call(:post, "/runs/uuid-956/stop")

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body) == %{"error" => "not_running"}
    end

    test "POST /issues/:identifier/run queues a manual run" do
      Application.put_env(:symphony_elixir, :cockpit_run_issue_fn, fn identifier ->
        send(self(), {:run_issue, identifier})
        {:ok, %{queued: true, mode: "run", identifier: identifier}}
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :cockpit_run_issue_fn) end)

      conn = call(:post, "/issues/SODEV-430/run")

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"queued" => true, "mode" => "run", "identifier" => "SODEV-430"}
      assert_received {:run_issue, "SODEV-430"}
    end

    test "POST /issues/:identifier/rerun preserves already-running conflicts" do
      Application.put_env(:symphony_elixir, :cockpit_rerun_issue_fn, fn _identifier -> {:error, :already_running} end)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :cockpit_rerun_issue_fn) end)

      conn = call(:post, "/issues/SODEV-430/rerun")

      assert conn.status == 409
      assert Jason.decode!(conn.resp_body) == %{"error" => "already_running"}
    end

    test "POST /issues/:identifier/reset resets local orchestrator pointers" do
      Application.put_env(:symphony_elixir, :cockpit_reset_issue_fn, fn identifier ->
        {:ok, %{reset: true, identifier: identifier, preserved: ["workspace"]}}
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :cockpit_reset_issue_fn) end)

      conn = call(:post, "/issues/SODEV-430/reset")

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"reset" => true, "identifier" => "SODEV-430", "preserved" => ["workspace"]}
    end
  end

  describe "auth" do
    test "passes through when no token is configured" do
      System.delete_env("SYMPHONY_COCKPIT_API_TOKEN")
      assert call(:get, "/health").status == 200
    end

    test "rejects a missing or wrong bearer when a token is set" do
      System.put_env("SYMPHONY_COCKPIT_API_TOKEN", "secret")
      on_exit(fn -> System.delete_env("SYMPHONY_COCKPIT_API_TOKEN") end)

      assert call(:get, "/health").status == 401
      assert call(:get, "/health", [{"authorization", "Bearer wrong"}]).status == 401
    end

    test "passes with the correct bearer token" do
      System.put_env("SYMPHONY_COCKPIT_API_TOKEN", "secret")
      on_exit(fn -> System.delete_env("SYMPHONY_COCKPIT_API_TOKEN") end)

      assert call(:get, "/health", [{"authorization", "Bearer secret"}]).status == 200
    end
  end

  describe "cockpit_children/0" do
    test "is empty unless the API port env is set" do
      System.delete_env("SYMPHONY_COCKPIT_API_PORT")
      assert SymphonyElixir.Application.cockpit_children() == []
    end

    test "adds an isolated Bandit child when the port is set" do
      System.put_env("SYMPHONY_COCKPIT_API_PORT", "41999")
      on_exit(fn -> System.delete_env("SYMPHONY_COCKPIT_API_PORT") end)

      assert [SymphonyElixir.Cockpit.BoardCache, {Bandit, opts}] =
               SymphonyElixir.Application.cockpit_children()

      assert opts[:plug] == SymphonyElixir.Cockpit.Api
      assert opts[:port] == 41_999
      assert opts[:ip] == {127, 0, 0, 1}
    end
  end
end
