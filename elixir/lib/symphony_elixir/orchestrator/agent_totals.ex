defmodule SymphonyElixir.Orchestrator.AgentTotals do
  @moduledoc """
  Aggregates per-agent token + rate-limit accounting onto the orchestrator
  `State` struct.

  Extracted from `SymphonyElixir.Orchestrator` (CP11). The orchestrator
  folds three pieces of accounting into the same `agent_totals` /
  `agent_rate_limits` slots: incremental token deltas from per-worker
  stream events, rate-limit snapshots scraped from those same events,
  and one-shot completion roll-ups when an issue terminates (which
  attribute the wall-clock seconds the agent was running, even though
  no token activity arrives at the moment of completion).

  All functions are pure transforms — they read and return the same
  `State` shape, with no process state or side effects.
  """

  alias SymphonyElixir.Orchestrator.TokenMetrics

  @doc """
  Fold a `token_delta` (input / output / total integer counters) into
  `state.agent_totals`. A malformed or empty delta is a no-op so the
  caller can pipe unconditionally.
  """
  def apply_token_delta(
        %{agent_totals: agent_totals} = state,
        %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
      )
      when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | agent_totals: merge_token_delta(agent_totals, token_delta)}
  end

  def apply_token_delta(state, _token_delta), do: state

  @doc """
  Replace `state.agent_rate_limits` with whatever `TokenMetrics`
  extracts from this `update`. Updates without rate-limit info leave
  the existing snapshot untouched.
  """
  def apply_rate_limits(state, update) when is_map(update) do
    case TokenMetrics.extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | agent_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  def apply_rate_limits(state, _update), do: state

  @doc """
  Roll the agent's wall-clock runtime into `state.agent_totals` when an
  issue terminates — no token deltas, but the elapsed seconds since
  `started_at` need to land in the cumulative `seconds_running` slot
  so the dashboard reflects total agent time.
  """
  def record_session_completion(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    agent_totals =
      merge_token_delta(
        state.agent_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | agent_totals: agent_totals}
  end

  def record_session_completion(state, _running_entry), do: state

  @doc """
  Whole-seconds elapsed between `started_at` and `now`, clamped at 0
  to absorb skewed clocks. Non-`DateTime` inputs collapse to 0 so the
  snapshot path stays total.
  """
  def running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  def running_seconds(_started_at, _now), do: 0

  defp merge_token_delta(agent_totals, token_delta) do
    input_tokens = Map.get(agent_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(agent_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(agent_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(agent_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end
end
