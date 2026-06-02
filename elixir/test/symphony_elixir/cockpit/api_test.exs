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
