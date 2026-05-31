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

  alias SymphonyElixir.Cockpit.{BoardCache, BoardView, Checks}
  alias SymphonyElixir.Config
  alias SymphonyElixir.RunLedger.Report
  alias SymphonyElixir.Tracker

  @default_runs_path "/opt/symphony/state/runs.jsonl"
  @default_status_path "/opt/symphony/state/status.json"

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
  def board, do: BoardCache.board(&assemble_board/0)

  @doc false
  @spec assemble_board() :: map()
  def assemble_board do
    tracker = Config.settings!().tracker
    issues = fetch_issues(BoardView.relevant_states(tracker))

    BoardView.assemble(issues, read_runs(), tracker,
      running: read_running(),
      ci: ci_map(issues)
    )
  end

  # CI status per PR url, fetched once per board build (bounded by BoardCache).
  defp ci_map(issues) do
    issues
    |> Enum.flat_map(&pr_urls/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn url ->
      case Checks.status(url) do
        nil -> []
        status -> [{url, status}]
      end
    end)
  end

  defp pr_urls(%{repos: repos}) when is_list(repos) do
    Enum.flat_map(repos, fn
      %{pr: %{url: url}} when is_binary(url) -> [url]
      %{"pr" => %{"url" => url}} when is_binary(url) -> [url]
      _ -> []
    end)
  end

  defp pr_urls(_), do: []

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

  # Internal issue ids with an agent running right now, from the orchestrator's
  # status.json (`.running`). Read-only; absent/garbled file -> no running marks.
  defp read_running do
    path = System.get_env("SYMPHONY_STATUS_PATH") || @default_status_path

    with {:ok, content} <- File.read(path),
         {:ok, %{"running" => running}} when is_list(running) <- Jason.decode(content) do
      running
    else
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
