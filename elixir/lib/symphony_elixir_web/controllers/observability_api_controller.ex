defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Config, Langfuse, Orchestrator, RunLedger, Tracker}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  # Linear stores issue-description images on uploads.linear.app, which 401s
  # without the tracker API token, so a browser <img> renders broken. The
  # cockpit rewrites those images to /linear-asset/* and this proxies the fetch
  # server-side with the token the dashboard never sees. The host is fixed, so
  # the path glob cannot be steered at another origin.
  @linear_asset_base "https://uploads.linear.app"

  @spec board(Conn.t(), map()) :: Conn.t()
  def board(conn, _params) do
    tracker = Config.settings!().tracker

    # Fetch the whole agent pipeline (not just the active queue) so every
    # lifecycle column can populate. The label/project filter still applies via
    # fetch_issues_by_states, so this stays scoped to the agent's own tickets.
    issues =
      case Tracker.fetch_issues_by_states(board_state_names(tracker)) do
        {:ok, issues} -> issues
        {:error, _reason} -> []
      end

    running_ids = running_issue_ids(orchestrator(), snapshot_timeout_ms())
    ledger = RunLedger.latest_by_identifier()

    json(conn, %{
      states: %{
        active: tracker.active_states,
        onComplete: tracker.review_state,
        onExhaust: nil,
        onPromote: tracker.ready_state,
        onPrMerge: nil,
        onReject: tracker.blocked_state,
        terminal: tracker.terminal_states,
        upNextExtra: [],
        doneExtra: tracker.done_extra_states,
        inProgressExtra: tracker.in_progress_states
      },
      tickets: Enum.map(issues, &ticket_payload(&1, running_ids, ledger))
    })
  end

  # The live pipeline states the cockpit shows, deduped and with unset mappings
  # dropped. Terminal states are intentionally excluded: the board is a live
  # view, so "Done" surfaces only recently-shipped work (done_extra), not the
  # full archive of closed tickets.
  @doc false
  def board_state_names(tracker) do
    [
      tracker.active_states,
      tracker.in_progress_states,
      [tracker.review_state, tracker.ready_state, tracker.blocked_state],
      tracker.done_extra_states
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @spec live(Conn.t(), map()) :: Conn.t()
  def live(conn, _params) do
    payload =
      case Orchestrator.snapshot(orchestrator(), snapshot_timeout_ms()) do
        %{} = snapshot ->
          %{
            available: true,
            agents: Enum.map(snapshot.running, &live_agent_payload/1),
            retrying: Enum.map(snapshot.retrying, &live_retry_payload/1),
            polling: live_polling_payload(snapshot.polling)
          }

        _ ->
          %{available: false, agents: [], retrying: [], polling: nil}
      end

    json(conn, payload)
  end

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec stop_run(Conn.t(), map()) :: Conn.t()
  def stop_run(conn, %{"issue_id" => issue_id}) do
    send_operation_result(conn, Orchestrator.stop_run(orchestrator(), issue_id))
  end

  @spec audit_issue(Conn.t(), map()) :: Conn.t()
  def audit_issue(conn, %{"identifier" => identifier}) do
    case find_board_issue(identifier) do
      %Issue{} = issue ->
        json(conn, %{
          identifier: issue.identifier,
          state: issue.state,
          pr_attached: false,
          evidence_items: 0,
          summary_available: false,
          url: issue.url
        })

      nil ->
        error_response(conn, 404, "not_found", "Issue not found")
    end
  end

  @spec run_issue(Conn.t(), map()) :: Conn.t()
  def run_issue(conn, %{"identifier" => identifier}) do
    send_operation_result(conn, Orchestrator.run_issue(orchestrator(), identifier))
  end

  @spec rerun_issue(Conn.t(), map()) :: Conn.t()
  def rerun_issue(conn, %{"identifier" => identifier}) do
    send_operation_result(conn, Orchestrator.rerun_issue(orchestrator(), identifier))
  end

  @spec reset_issue(Conn.t(), map()) :: Conn.t()
  def reset_issue(conn, %{"identifier" => identifier}) do
    send_operation_result(conn, Orchestrator.reset_issue(orchestrator(), identifier))
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  @spec linear_asset(Conn.t(), map()) :: Conn.t()
  def linear_asset(conn, %{"path" => segments}) do
    url = @linear_asset_base <> "/" <> Enum.map_join(segments, "/", &URI.encode/1)

    case linear_asset_fetcher().(url) do
      {:ok, %{body: body, content_type: ctype}} ->
        conn
        |> Conn.put_resp_content_type(ctype, nil)
        |> Conn.put_resp_header("cache-control", "private, max-age=300")
        |> Conn.send_resp(200, body)

      _ ->
        error_response(conn, 404, "not_found", "Linear asset not found")
    end
  end

  defp linear_asset_fetcher do
    Application.get_env(:symphony_elixir, :linear_asset_fetcher, &default_linear_asset_fetch/1)
  end

  defp default_linear_asset_fetch(url) do
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

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp send_operation_result(conn, {:ok, result}), do: json(conn, result)

  defp send_operation_result(conn, {:error, :already_running}) do
    error_response(conn, 409, "already_running", "Issue already has an active run")
  end

  defp send_operation_result(conn, {:error, :not_active}) do
    error_response(conn, 409, "not_active", "Issue is not in an active Symphony state")
  end

  defp send_operation_result(conn, {:error, :no_capacity}) do
    error_response(conn, 409, "no_capacity", "No Symphony agent slot is currently available")
  end

  defp send_operation_result(conn, {:error, :not_found}) do
    error_response(conn, 404, "not_found", "Issue not found")
  end

  defp send_operation_result(conn, {:error, :not_running}) do
    error_response(conn, 404, "not_running", "Issue is not running")
  end

  defp send_operation_result(conn, {:error, :unavailable}) do
    error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
  end

  defp send_operation_result(conn, {:error, reason}) do
    error_response(conn, 502, "operation_failed", inspect(reason))
  end

  defp board_states(tracker) do
    (tracker.active_states ++ tracker.terminal_states)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
  end

  defp running_issue_ids(orchestrator, timeout) do
    case Orchestrator.snapshot(orchestrator, timeout) do
      %{} = snapshot ->
        snapshot.running
        |> Enum.map(&Map.get(&1, :issue_id))
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp ticket_payload(%Issue{} = issue, running_ids, ledger) do
    running? = MapSet.member?(running_ids, issue.id)
    # A still-running ticket gets its trace from the live overlay; only finished
    # tickets read the persisted run ledger, so a stale prior run never shows.
    record = unless running?, do: Map.get(ledger, issue.identifier)

    %{
      id: issue.identifier,
      title: issue.title,
      description: issue.description,
      state: issue.state,
      agent: %{
        status: if(running?, do: "running", else: "idle"),
        turn: nil,
        maxTurns: nil,
        costUsd: nil,
        lastAction: nil
      },
      pr: pr_payload(issue),
      evidence: [],
      report: nil,
      summary: ledger_summary(record),
      timeline: [],
      url: issue.url,
      traceUrl: ledger_trace_url(record),
      updatedAt: issue.updated_at || ""
    }
  end

  defp ledger_summary(%{"summary" => summary}) when is_binary(summary), do: summary
  defp ledger_summary(_record), do: nil

  defp ledger_trace_url(%{"traceUrl" => url}) when is_binary(url), do: url
  defp ledger_trace_url(_record), do: nil

  # The agent's GitHub PR comes from the Linear issue attachment (the run ledger
  # the fork used for this was stripped in the migration). CI status needs a
  # GitHub call we do not make here, so it stays nil; the cockpit contract allows
  # a null ci/url.
  defp pr_payload(%Issue{pr: %{url: url, number: number}}) do
    %{number: number, url: url, ci: nil}
  end

  defp pr_payload(_issue), do: nil

  defp live_agent_payload(entry) do
    %{
      id: Map.get(entry, :identifier),
      issueId: Map.get(entry, :issue_id),
      state: Map.get(entry, :state),
      turn: Map.get(entry, :turn_count, 0),
      phase: live_phase(Map.get(entry, :last_codex_event)),
      lastAction: summarize_live_message(Map.get(entry, :last_codex_message)),
      lastEvent: stringify(Map.get(entry, :last_codex_event)),
      events: live_events_payload(Map.get(entry, :recent_events, [])),
      runtimeSeconds: Map.get(entry, :runtime_seconds),
      startedAt: iso8601(Map.get(entry, :started_at)),
      lastActivityAt: iso8601(Map.get(entry, :last_codex_timestamp)),
      tokens: %{
        in: Map.get(entry, :codex_input_tokens, 0),
        out: Map.get(entry, :codex_output_tokens, 0),
        total: Map.get(entry, :codex_total_tokens, 0)
      },
      sessionId: Map.get(entry, :session_id),
      workerHost: Map.get(entry, :worker_host),
      costUsd: nil,
      traceUrl: Langfuse.trace_url(Map.get(entry, :session_id))
    }
  end

  defp live_retry_payload(entry) do
    %{
      id: Map.get(entry, :identifier) || Map.get(entry, :issue_id),
      attempt: Map.get(entry, :attempt),
      dueInMs: Map.get(entry, :due_in_ms),
      error: Map.get(entry, :error)
    }
  end

  defp live_polling_payload(nil), do: nil

  defp live_polling_payload(polling) do
    %{
      checking: Map.get(polling, :checking?, false),
      nextPollInMs: Map.get(polling, :next_poll_in_ms),
      intervalMs: Map.get(polling, :poll_interval_ms)
    }
  end

  defp live_phase(event) when event in [:turn_input_required, :approval_required], do: "blocked"
  defp live_phase(:turn_failed), do: "failed"
  defp live_phase(:turn_ended_with_error), do: "failed"
  defp live_phase(:turn_cancelled), do: "cancelled"
  defp live_phase(nil), do: "starting"
  defp live_phase(_event), do: "building"

  # Format the orchestrator's recent-events ring buffer into the live timeline
  # contract: {event, action, at}, newest first (already ordered by the buffer).
  defp live_events_payload(events) when is_list(events) do
    Enum.map(events, fn event ->
      %{
        event: stringify(Map.get(event, :event)),
        action: summarize_live_message(Map.get(event, :action)),
        at: iso8601(Map.get(event, :at))
      }
    end)
  end

  defp live_events_payload(_events), do: []

  defp summarize_live_message(nil), do: nil
  defp summarize_live_message(message), do: SymphonyElixir.StatusDashboard.humanize_codex_message(message)

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(_value), do: nil

  defp find_board_issue(identifier) when is_binary(identifier) do
    normalized = identifier |> String.trim() |> String.upcase()

    Config.settings!().tracker
    |> board_states()
    |> Tracker.fetch_issues_by_states()
    |> case do
      {:ok, issues} ->
        Enum.find(issues, fn
          %Issue{identifier: issue_identifier} when is_binary(issue_identifier) ->
            String.upcase(issue_identifier) == normalized

          _ ->
            false
        end)

      {:error, _reason} ->
        nil
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
