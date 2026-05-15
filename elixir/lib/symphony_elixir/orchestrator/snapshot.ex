defmodule SymphonyElixir.Orchestrator.Snapshot do
  @moduledoc """
  Builds the public state snapshot returned to dashboard / status
  callers from the orchestrator's internal `State` struct.

  Extracted from `SymphonyElixir.Orchestrator` (CP12). The shape is
  the same payload `handle_call(:snapshot, ...)` used to assemble
  inline: a list of per-issue running entries, a list of pending
  retry attempts, the cumulative agent token totals, the most
  recently observed rate-limit snapshot, and a polling sub-map with
  drain / next-tick metadata.

  All functions are pure — `build/3` takes the orchestrator state
  plus the two clocks (`DateTime.utc_now()` and
  `System.monotonic_time(:millisecond)`) the caller already has and
  produces a fully materialized map. Callers stay responsible for
  reading the clocks so the GenServer can keep its single source of
  truth.
  """

  alias SymphonyElixir.Orchestrator.AgentTotals

  @doc """
  Build the snapshot map for `state` given the wall-clock `now`
  (used to compute per-issue runtime seconds) and monotonic `now_ms`
  (used to compute pending retry due-in deltas and the next-poll
  countdown).
  """
  def build(state, %DateTime{} = now, now_ms) when is_integer(now_ms) do
    %{
      running: running_projection(state, now),
      retrying: retrying_projection(state, now_ms),
      agent_totals: state.agent_totals,
      rate_limits: Map.get(state, :agent_rate_limits),
      polling: polling_projection(state, now_ms)
    }
  end

  defp running_projection(state, now) do
    state.running
    |> Enum.map(fn {issue_id, metadata} ->
      %{
        issue_id: issue_id,
        identifier: metadata.identifier,
        state: metadata.issue.state,
        worker_host: Map.get(metadata, :worker_host),
        workspace_path: Map.get(metadata, :workspace_path),
        session_id: metadata.session_id,
        agent_pid: metadata.agent_pid,
        agent_input_tokens: metadata.agent_input_tokens,
        agent_output_tokens: metadata.agent_output_tokens,
        agent_total_tokens: metadata.agent_total_tokens,
        turn_count: Map.get(metadata, :turn_count, 0),
        started_at: metadata.started_at,
        last_agent_timestamp: metadata.last_agent_timestamp,
        last_agent_message: metadata.last_agent_message,
        last_agent_event: metadata.last_agent_event,
        runtime_seconds: AgentTotals.running_seconds(metadata.started_at, now)
      }
    end)
  end

  defp retrying_projection(state, now_ms) do
    state.retry_attempts
    |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
      %{
        issue_id: issue_id,
        attempt: attempt,
        due_in_ms: max(0, due_at_ms - now_ms),
        identifier: Map.get(retry, :identifier),
        error: Map.get(retry, :error),
        worker_host: Map.get(retry, :worker_host),
        workspace_path: Map.get(retry, :workspace_path)
      }
    end)
  end

  defp polling_projection(state, now_ms) do
    %{
      checking?: state.poll_check_in_progress == true,
      next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
      poll_interval_ms: state.poll_interval_ms
    }
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end
end
