defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Config, Orchestrator, Tracker}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec board(Conn.t(), map()) :: Conn.t()
  def board(conn, _params) do
    settings = Config.settings!()
    states = settings.tracker.active_states

    issues =
      case Tracker.fetch_issues_by_states(states) do
        {:ok, issues} -> issues
        {:error, _reason} -> []
      end

    running_ids = running_issue_ids(orchestrator(), snapshot_timeout_ms())

    json(conn, %{
      states: %{
        active: settings.tracker.active_states,
        onComplete: nil,
        onExhaust: nil,
        onPromote: nil,
        onPrMerge: nil,
        onReject: nil,
        terminal: settings.tracker.terminal_states,
        upNextExtra: [],
        doneExtra: [],
        inProgressExtra: []
      },
      tickets: Enum.map(issues, &ticket_payload(&1, running_ids))
    })
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

  defp ticket_payload(%Issue{} = issue, running_ids) do
    running? = MapSet.member?(running_ids, issue.id)

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
      pr: nil,
      evidence: [],
      report: nil,
      summary: nil,
      timeline: [],
      url: issue.url,
      traceUrl: nil,
      updatedAt: issue.updated_at || ""
    }
  end

  defp live_agent_payload(entry) do
    %{
      id: Map.get(entry, :identifier),
      issueId: Map.get(entry, :issue_id),
      state: Map.get(entry, :state),
      turn: Map.get(entry, :turn_count, 0),
      phase: live_phase(Map.get(entry, :last_codex_event)),
      lastAction: summarize_live_message(Map.get(entry, :last_codex_message)),
      lastEvent: stringify(Map.get(entry, :last_codex_event)),
      events: [],
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
      traceUrl: langfuse_trace_url(entry)
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

  defp langfuse_trace_url(entry) do
    with {:ok, config} <- langfuse_config(),
         {:ok, turn_id} <- session_turn_id(Map.get(entry, :session_id)),
         {:ok, trace} <- fetch_langfuse_trace(config, turn_id) do
      langfuse_trace_url(config.host, trace)
    else
      _ -> nil
    end
  end

  defp langfuse_config do
    host = System.get_env("LANGFUSE_HOST") || System.get_env("LANGFUSE_BASE_URL")
    public_key = System.get_env("LANGFUSE_PUBLIC_KEY")
    secret_key = System.get_env("LANGFUSE_SECRET_KEY") || System.get_env("LANGFUSE_SECRET")

    if present?(host) and present?(public_key) and present?(secret_key) do
      {:ok, %{host: String.trim_trailing(host, "/"), public_key: public_key, secret_key: secret_key}}
    else
      :error
    end
  end

  defp session_turn_id(session_id) when is_binary(session_id) do
    case String.split(session_id, "-", parts: 6) do
      [_, _, _, _, _, turn_id] when byte_size(turn_id) > 0 -> {:ok, turn_id}
      _ -> :error
    end
  end

  defp session_turn_id(_session_id), do: :error

  defp fetch_langfuse_trace(%{host: host, public_key: public_key, secret_key: secret_key}, turn_id) do
    auth = Base.encode64("#{public_key}:#{secret_key}")

    case Req.get("#{host}/api/public/traces",
           params: [limit: 50],
           headers: [{"authorization", "Basic #{auth}"}],
           receive_timeout: 1_500
         ) do
      {:ok, %{status: status, body: %{"data" => traces}}} when status in 200..299 ->
        traces
        |> Enum.find(&trace_matches_turn_id?(&1, turn_id))
        |> case do
          nil -> :error
          trace -> {:ok, trace}
        end

      _ ->
        :error
    end
  end

  defp trace_matches_turn_id?(%{"metadata" => %{"attributes" => attributes}}, turn_id) when is_map(attributes) do
    Map.get(attributes, "turn.id") == turn_id
  end

  defp trace_matches_turn_id?(_trace, _turn_id), do: false

  defp langfuse_trace_url(host, %{"htmlPath" => html_path}) when is_binary(html_path) do
    host <> html_path
  end

  defp langfuse_trace_url(_host, %{"id" => id, "projectId" => project_id})
       when is_binary(id) and is_binary(project_id) do
    "https://cloud.langfuse.com/project/#{project_id}/traces/#{id}"
  end

  defp langfuse_trace_url(_host, _trace), do: nil

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

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
