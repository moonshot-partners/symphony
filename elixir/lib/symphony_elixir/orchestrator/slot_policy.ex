defmodule SymphonyElixir.Orchestrator.SlotPolicy do
  @moduledoc """
  Pure decision helpers for the orchestrator's dispatch gate: how many
  global slots are still available, whether a given issue's per-state
  cap has slack, and the full `should_dispatch?/4` predicate that
  combines the slot checks with the existing `DispatchGate` /
  `WorkerSelector` rules.

  Extracted from `SymphonyElixir.Orchestrator` (CP17). None of these
  functions reach into the GenServer process — they take the bare
  `%State{}` (or its components) and an issue, and return booleans /
  counts. The orchestrator keeps the side-effecting `dispatch_issue`
  call and only delegates the math here.
  """

  alias SymphonyElixir.{Config, Linear.Issue}
  alias SymphonyElixir.Orchestrator.{DispatchGate, State, WorkerSelector}

  @doc """
  Returns the number of additional agents the orchestrator may spawn
  globally. Falls back to `Config.settings!().agent.max_concurrent_agents`
  when `state.max_concurrent_agents` is nil. Always clamped at zero.
  """
  @spec available_slots(State.t()) :: non_neg_integer()
  def available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @doc """
  Returns true when fewer running agents share `issue`'s Linear state
  than the configured per-state cap. Returns false on non-Issue / non-map
  inputs (defensive — orchestrator currently never feeds bad data here
  but the original implementation guarded for it).
  """
  @spec state_slots_available?(any(), any()) :: boolean()
  def state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_count_for_state(running, issue_state)
    limit > used
  end

  def state_slots_available?(_issue, _running), do: false

  @doc """
  Returns true when both the global slot cap (`available_slots/1 > 0`)
  and the per-state cap (`state_slots_available?/2`) have slack.
  Equivalent to the orchestrator's pre-extraction
  `dispatch_slots_available?/2`.
  """
  @spec dispatch_slots_available?(Issue.t(), State.t()) :: boolean()
  def dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  @doc """
  Full dispatch predicate: combines `DispatchGate.candidate?/3`,
  `DispatchGate.todo_blocked_by_non_terminal?/2`, the `claimed` /
  `running` membership checks, the slot caps, and the worker-selector
  capacity check.
  """
  @spec should_dispatch?(any(), State.t(), MapSet.t(), MapSet.t()) :: boolean()
  def should_dispatch?(
        %Issue{} = issue,
        %State{running: running, claimed: claimed} = state,
        active_states,
        terminal_states
      ) do
    DispatchGate.candidate?(issue, active_states, terminal_states) and
      !DispatchGate.todo_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      WorkerSelector.slots_available?(state)
  end

  def should_dispatch?(_issue, _state, _active_states, _terminal_states), do: false

  defp running_count_for_state(running, issue_state) do
    normalized_state = DispatchGate.normalize_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        DispatchGate.normalize_state(state_name) == normalized_state

      _ ->
        false
    end)
  end
end
