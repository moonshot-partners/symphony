defmodule SymphonyElixir.Orchestrator.AgentUpdate do
  @moduledoc """
  Merges per-worker agent stream events into a `running` entry.

  Extracted from `SymphonyElixir.Orchestrator` (CP10). The orchestrator
  receives `{:agent_worker_update, issue_id, update}` messages from each
  spawned agent worker and folds the update into its bookkeeping map for
  that issue: token deltas accumulate, session boundaries roll the turn
  counter, and the most recent event tag + timestamp are recorded for
  the dashboard / status snapshot.

  All functions are pure transforms over the `running_entry` map and the
  `update` payload — no process state, no side effects. The single
  public entry point is `integrate/2`.
  """

  alias SymphonyElixir.Orchestrator.{AgentAction, TokenMetrics}

  # Last N agent actions kept for the cockpit's live timeline. Bounded so a
  # long run can't grow the running entry without limit.
  @max_recent_events 20

  @doc """
  Apply a single agent worker update to the existing `running_entry`,
  returning the updated entry plus the token delta extracted from the
  update (so the caller can roll the orchestrator-level token totals).
  """
  def integrate(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = TokenMetrics.extract_token_delta(running_entry, update)
    agent_input_tokens = Map.get(running_entry, :agent_input_tokens, 0)
    agent_output_tokens = Map.get(running_entry, :agent_output_tokens, 0)
    agent_total_tokens = Map.get(running_entry, :agent_total_tokens, 0)
    agent_pid = Map.get(running_entry, :agent_pid)
    last_reported_input = Map.get(running_entry, :agent_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :agent_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :agent_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)
    summary = summarize_update(update)

    {
      Map.merge(running_entry, %{
        last_agent_timestamp: timestamp,
        last_agent_message: summary,
        recent_events: push_event(running_entry, event, summary, timestamp),
        session_id: session_id_for_update(running_entry.session_id, update),
        langfuse_trace_id: trace_id_for_update(Map.get(running_entry, :langfuse_trace_id), update),
        agent_cost_usd: cost_for_update(Map.get(running_entry, :agent_cost_usd), update),
        last_agent_event: event,
        agent_pid: agent_pid_for_update(agent_pid, update),
        agent_input_tokens: agent_input_tokens + token_delta.input_tokens,
        agent_output_tokens: agent_output_tokens + token_delta.output_tokens,
        agent_total_tokens: agent_total_tokens + token_delta.total_tokens,
        agent_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        agent_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        agent_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp agent_pid_for_update(_existing, %{agent_pid: pid})
       when is_binary(pid),
       do: pid

  defp agent_pid_for_update(_existing, %{agent_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp agent_pid_for_update(_existing, %{agent_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp agent_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  # The shim attaches the Langfuse trace id to the turn/completed params (when
  # tracing is on). It arrives once per turn, so latch the first binary value
  # and keep it across later updates that don't carry one.
  defp trace_id_for_update(existing, update) do
    case update[:payload] do
      %{"params" => %{"langfuse_trace_id" => trace_id}}
      when is_binary(trace_id) and trace_id != "" ->
        trace_id

      _ ->
        existing
    end
  end

  # The shim reports the Claude SDK's cumulative session cost on each
  # turn/completed. It is cumulative, so the latest value is the run total;
  # latch the most recent number and keep it when an update carries none.
  defp cost_for_update(existing, update) do
    case update[:payload] do
      %{"params" => %{"total_cost_usd" => cost}} when is_number(cost) and cost >= 0 ->
        cost

      _ ->
        existing
    end
  end

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp push_event(running_entry, event, summary, timestamp) do
    entry = %{event: event, action: AgentAction.line(summary), at: timestamp}

    [entry | Map.get(running_entry, :recent_events, [])]
    |> Enum.take(@max_recent_events)
  end
end
