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
