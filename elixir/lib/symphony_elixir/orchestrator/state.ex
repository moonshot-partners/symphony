defmodule SymphonyElixir.Orchestrator.State do
  @moduledoc """
  Runtime state for the orchestrator polling loop.

  Extracted from `SymphonyElixir.Orchestrator` so reconcile and dispatch
  helpers can live in sibling modules without circular references back
  into the GenServer module.
  """

  defstruct [
    :poll_interval_ms,
    :max_concurrent_agents,
    :next_poll_due_at_ms,
    :poll_check_in_progress,
    :tick_timer_ref,
    :tick_token,
    running: %{},
    completed: MapSet.new(),
    claimed: MapSet.new(),
    retry_attempts: %{},
    workpads: %{},
    agent_totals: nil,
    agent_rate_limits: nil
  ]
end
