defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          agent_totals: snapshot.agent_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

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

  @spec board_payload(
          (-> {:ok, [SymphonyElixir.Linear.Issue.t()]} | {:error, term()}),
          GenServer.name(),
          timeout()
        ) :: map()
  def board_payload(fetcher, orchestrator, snapshot_timeout_ms) when is_function(fetcher, 0) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    snapshot = Orchestrator.snapshot(orchestrator, snapshot_timeout_ms)

    case fetcher.() do
      {:ok, issues} ->
        running_index = build_running_index(snapshot)
        retrying_index = build_retrying_index(snapshot)

        %{
          generated_at: generated_at,
          columns: build_board_columns(issues, running_index, retrying_index)
        }

      {:error, _reason} ->
        %{
          generated_at: generated_at,
          columns: empty_board_columns(),
          error: %{code: "linear_unavailable", message: "Linear API unreachable"}
        }
    end
  end

  defp build_running_index(%{running: running}) when is_list(running),
    do: Map.new(running, &{&1.issue_id, &1})

  defp build_running_index(_), do: %{}

  defp build_retrying_index(%{retrying: retrying}) when is_list(retrying),
    do: Map.new(retrying, &{&1.issue_id, &1})

  defp build_retrying_index(_), do: %{}

  defp empty_board_columns do
    Enum.map(@board_columns, fn %{key: k, label: l, linear_states: s} ->
      %{key: k, label: l, linear_states: s, issues: []}
    end)
  end

  defp build_board_columns(issues, running_index, retrying_index) do
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

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        agent_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_agent_event,
      last_message: summarize_message(entry.last_agent_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_agent_timestamp),
      tokens: %{
        input_tokens: entry.agent_input_tokens,
        output_tokens: entry.agent_output_tokens,
        total_tokens: entry.agent_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_agent_event,
      last_message: summarize_message(running.last_agent_message),
      last_event_at: iso8601(running.last_agent_timestamp),
      tokens: %{
        input_tokens: running.agent_input_tokens,
        output_tokens: running.agent_output_tokens,
        total_tokens: running.agent_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_agent_timestamp),
        event: running.last_agent_event,
        message: summarize_message(running.last_agent_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_agent_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
