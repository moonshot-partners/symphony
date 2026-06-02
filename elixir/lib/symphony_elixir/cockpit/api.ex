defmodule SymphonyElixir.Cockpit.Api do
  @moduledoc """
  Read-only HTTP API for the cockpit dashboard. Serves the board payload
  assembled from the tracker + run ledger, plus a live runtime snapshot of the
  agents the orchestrator is running right now. Started only when
  `SYMPHONY_COCKPIT_API_PORT` is set (see `SymphonyElixir.Application`), so it is
  inert in any deployment that does not opt in.

  Read-only by construction: no route mutates orchestrator or tracker state.
  An optional bearer token (`SYMPHONY_COCKPIT_API_TOKEN`) gates access.
  """

  use Plug.Router

  alias SymphonyElixir.Cockpit.{BoardCache, BoardView, Checks, EvidenceStore, LiveView, RunSummaryStore}
  alias SymphonyElixir.Config
  alias SymphonyElixir.RunLedger.Report
  alias SymphonyElixir.Tracker

  @default_runs_path "/opt/symphony/state/runs.jsonl"
  @default_status_path "/opt/symphony/state/status.json"
  @linear_asset_base "https://uploads.linear.app"

  plug(:auth)
  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_json(conn, 200, %{"status" => "ok"})
  end

  get "/board" do
    send_json(conn, 200, board())
  end

  get "/live" do
    send_json(conn, 200, live())
  end

  get "/evidence/:id/:file" do
    case EvidenceStore.file_path(id, file) do
      nil -> send_json(conn, 404, %{"error" => "not_found"})
      path -> serve_file(conn, path)
    end
  end

  # Linear stores issue-description images on `uploads.linear.app`, which 401s
  # without the tracker API token, so a browser <img> renders a broken image.
  # This proxies the fetch server-side with the token the dashboard never sees,
  # mirroring the evidence proxy. The host is fixed, so the path glob cannot be
  # steered at another origin.
  get "/linear-asset/*path" do
    serve_linear_asset(conn, path)
  end

  match _ do
    send_json(conn, 404, %{"error" => "not_found"})
  end

  @doc false
  @spec board() :: map()
  def board, do: BoardCache.board(&assemble_board/0)

  @doc false
  @spec live() :: map()
  def live, do: LiveView.render(snapshot_source().())

  # The orchestrator's in-memory runtime snapshot. Reached in-process (the API
  # and the orchestrator share the BEAM node) and never cached: this is the live
  # regime, refreshed every poll the browser makes. Indirected through the app
  # env so tests inject a canned snapshot instead of standing up the GenServer.
  defp snapshot_source do
    Application.get_env(
      :symphony_elixir,
      :cockpit_snapshot_fn,
      &SymphonyElixir.Orchestrator.snapshot/0
    )
  end

  @doc false
  @spec assemble_board() :: map()
  def assemble_board do
    settings = Config.settings!()
    tracker = settings.tracker
    cockpit = settings.cockpit

    # Board display states: the agent's lifecycle states plus the cockpit-only
    # extras (Up next backlog, Done post-QA). The extras never touch the agent's
    # dispatch/terminal config — they only widen what the board shows.
    done = MapSet.new(List.wrap(tracker.terminal_states) ++ cockpit.done_states)

    {done_states, active_states} =
      (BoardView.relevant_states(tracker) ++
         cockpit.up_next_states ++ cockpit.done_states ++ cockpit.in_progress_states)
      |> Enum.uniq()
      |> Enum.split_with(&MapSet.member?(done, &1))

    # Both groups fetch only the routing-labelled issues (the agent's scope),
    # first page only — never paginate the whole team backlog. That backlog,
    # unfiltered + paginated, is what exhausted the shared Linear rate limit and
    # also put non-agent tickets on the board.
    issues = fetch_recent_issues(active_states) ++ fetch_recent_issues(done_states)

    BoardView.assemble(issues, read_runs(), tracker,
      running: read_running(),
      ci: ci_map(BoardView.ci_candidates(issues, tracker)),
      evidence: evidence_map(issues),
      summary: summary_map(issues),
      extra_up_next: cockpit.up_next_states,
      extra_done: cockpit.done_states,
      extra_in_progress: cockpit.in_progress_states
    )
  end

  # QA evidence manifest per issue, read from the local cockpit store. Cheap
  # local disk reads, bounded by the board cache; keyed by internal issue id.
  defp evidence_map(issues) do
    Map.new(issues, fn issue -> {issue.id, EvidenceStore.read(issue.id)} end)
  end

  # Completion summary markdown per issue, read from the local cockpit store.
  defp summary_map(issues) do
    Map.new(issues, fn issue -> {issue.id, RunSummaryStore.read(issue.id)} end)
  end

  # CI status per PR url, fetched once per board build (bounded by BoardCache).
  # Each `Checks.status` shells `gh pr view` (network), so the lookups run
  # concurrently with a per-call timeout: a slow or hung `gh` can no longer
  # serialize the whole board build past the 30s cache call timeout.
  defp ci_map(issues) do
    issues
    |> Enum.flat_map(&pr_urls/1)
    |> Enum.uniq()
    |> Task.async_stream(fn url -> {url, Checks.status(url)} end,
      max_concurrency: 16,
      timeout: 8_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, {url, status}} when is_binary(status) -> [{url, status}]
      _ -> []
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

  defp fetch_recent_issues([]), do: []

  defp fetch_recent_issues(states) do
    case Tracker.fetch_recent_issues_by_states(states) do
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

  defp serve_linear_asset(conn, segments) do
    url = @linear_asset_base <> "/" <> Enum.map_join(segments, "/", &URI.encode/1)

    case asset_fetcher().(url) do
      {:ok, %{body: body, content_type: ctype}} ->
        conn
        |> Plug.Conn.put_resp_content_type(ctype, nil)
        |> Plug.Conn.put_resp_header("cache-control", "private, max-age=300")
        |> Plug.Conn.send_resp(200, body)

      _ ->
        send_json(conn, 404, %{"error" => "not_found"})
    end
  end

  defp asset_fetcher do
    Application.get_env(:symphony_elixir, :linear_asset_fetcher, &default_asset_fetch/1)
  end

  defp default_asset_fetch(url) do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_token}

      token ->
        case Req.get(url, headers: [{"authorization", token}], decode_body: false) do
          {:ok, %Req.Response{status: 200, body: body} = resp} ->
            ctype =
              resp
              |> Req.Response.get_header("content-type")
              |> List.first()
              |> Kernel.||("application/octet-stream")

            {:ok, %{body: body, content_type: ctype}}

          {:ok, %Req.Response{status: status}} ->
            {:error, {:http, status}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp serve_file(conn, path) do
    conn
    |> Plug.Conn.put_resp_content_type(content_type(path))
    |> Plug.Conn.send_file(200, path)
  end

  defp content_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".webm" -> "video/webm"
      ".mp4" -> "video/mp4"
      _ -> "application/octet-stream"
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
