defmodule SymphonyElixir.Cockpit.Api do
  @moduledoc """
  Read-only HTTP API for the cockpit dashboard. Serves the board payload
  assembled from the tracker + run ledger. Started only when
  `SYMPHONY_COCKPIT_API_PORT` is set (see `SymphonyElixir.Application`), so it is
  inert in any deployment that does not opt in.

  Read-only by construction: no route mutates orchestrator or tracker state.
  An optional bearer token (`SYMPHONY_COCKPIT_API_TOKEN`) gates access.
  """

  use Plug.Router

  alias SymphonyElixir.Cockpit.BoardView
  alias SymphonyElixir.Config
  alias SymphonyElixir.RunLedger.Report
  alias SymphonyElixir.Tracker

  @default_runs_path "/opt/symphony/state/runs.jsonl"

  plug(:auth)
  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_json(conn, 200, %{"status" => "ok"})
  end

  get "/board" do
    send_json(conn, 200, board())
  end

  match _ do
    send_json(conn, 404, %{"error" => "not_found"})
  end

  @doc false
  @spec board() :: map()
  def board do
    tracker = Config.settings!().tracker
    issues = fetch_issues(BoardView.relevant_states(tracker))
    BoardView.assemble(issues, read_runs(), tracker)
  end

  defp fetch_issues(states) do
    case Tracker.fetch_issues_by_states(states) do
      {:ok, issues} -> issues
      _ -> []
    end
  end

  defp read_runs do
    path = System.get_env("SYMPHONY_RUNS_PATH") || @default_runs_path

    case File.read(path) do
      {:ok, content} -> Report.parse_lines(content)
      _ -> []
    end
  end

  defp auth(conn, _opts) do
    case System.get_env("SYMPHONY_COCKPIT_API_TOKEN") do
      token when is_binary(token) and token != "" ->
        if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> token] do
          conn
        else
          conn |> send_json(401, %{"error" => "unauthorized"}) |> Plug.Conn.halt()
        end

      _ ->
        conn
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
