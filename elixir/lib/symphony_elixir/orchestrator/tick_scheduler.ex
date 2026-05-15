defmodule SymphonyElixir.Orchestrator.TickScheduler do
  @moduledoc """
  Tick / poll-cycle scheduling helpers extracted from
  `SymphonyElixir.Orchestrator` (CP20). The orchestrator drives its
  reconcile loop with three primitives:

    * `schedule_tick/3` — (re)arm the periodic `:tick` timer carrying
      a fresh token so a late delivery from a previous tick is safely
      ignored.
    * `schedule_poll_cycle_start/2` — fire `:run_poll_cycle` after a
      short delay so the dashboard can render the "checking now…"
      transition before the poll work starts.
    * `refresh_runtime_config/1` — copy `poll_interval_ms` and
      `max_concurrent_agents` from the live `Config.settings!()` onto
      the orchestrator state.

  The recipient pid is threaded explicitly so the sibling does not
  capture `self()` and remains testable with an arbitrary process.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Orchestrator.State

  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20

  @doc """
  Cancel the orchestrator's current tick timer (if any), arm a new
  one for `delay_ms`, and return the updated `%State{}` with the
  fresh `tick_timer_ref`, `tick_token`, and `next_poll_due_at_ms`.
  """
  @spec schedule_tick(State.t(), non_neg_integer(), pid()) :: State.t()
  def schedule_tick(%State{} = state, delay_ms, recipient)
      when is_integer(delay_ms) and delay_ms >= 0 and is_pid(recipient) do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(recipient, {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  @doc """
  Fire `:run_poll_cycle` against `recipient` after the configured
  render-delay (default `#{@poll_transition_render_delay_ms}ms`).
  Returns `:ok`.
  """
  @spec schedule_poll_cycle_start(pid(), non_neg_integer()) :: :ok
  def schedule_poll_cycle_start(recipient, delay_ms \\ @poll_transition_render_delay_ms)
      when is_pid(recipient) and is_integer(delay_ms) and delay_ms >= 0 do
    :timer.send_after(delay_ms, recipient, :run_poll_cycle)
    :ok
  end

  @doc """
  Refresh the orchestrator's runtime-tunable fields
  (`poll_interval_ms`, `max_concurrent_agents`) from the live
  workflow config.
  """
  @spec refresh_runtime_config(State.t()) :: State.t()
  def refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end
end
