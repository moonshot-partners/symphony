defmodule SymphonyElixir.Orchestrator.GateCEnforcement do
  @moduledoc """
  Hard-gate enforcement for Gate C (AC Extracted) violations during the
  agent's first turn. Sibling to `PreDispatch` — same intent, fires from
  inside an already-running agent session.

  `enforce/5` is the single API:

    * `:ok` → returns `{:continue, state}` and the orchestrator keeps
      the running agent alive.
    * `{:violation, reason}` → records a parked-issue summary in the cockpit
      run summary store, moves the issue to `tracker.on_reject_state`, calls
      the orchestrator-supplied `terminate_fn` to kill the running task, and
      marks the issue completed so reconcile does not redispatch it. Returns
      `{:halted, state}`.

  The summary write is a fast, non-raising local-disk write done inline; the
  state move (tracker I/O) runs inside a `Task.Supervisor.start_child` so the
  orchestrator process is never blocked on the network.
  """

  require Logger

  alias SymphonyElixir.Cockpit.RunSummaryStore
  alias SymphonyElixir.Config
  alias SymphonyElixir.Orchestrator.{State, StateTransition}

  @type gate_c_result :: :ok | {:violation, atom()}
  @type opts :: [terminate_fn: (State.t(), String.t(), boolean() -> State.t())]

  @spec enforce(gate_c_result(), State.t(), String.t(), map(), opts()) ::
          {:continue, State.t()} | {:halted, State.t()}
  def enforce(:ok, %State{} = state, _issue_id, _running_entry, _opts), do: {:continue, state}

  def enforce({:violation, reason}, %State{} = state, issue_id, running_entry, opts)
      when is_binary(issue_id) and is_map(running_entry) and is_list(opts) do
    terminate_fn = Keyword.fetch!(opts, :terminate_fn)
    identifier = Map.get(running_entry, :identifier, issue_id)
    issue = Map.get(running_entry, :issue)
    on_reject_state = Config.settings!().tracker.on_reject_state

    Logger.warning("Gate C hard halt: issue_id=#{issue_id} issue_identifier=#{identifier} reason=#{reason}")

    RunSummaryStore.put(issue_id, violation_comment(reason, identifier))

    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      StateTransition.apply(issue, on_reject_state)
    end)

    state = terminate_fn.(state, issue_id, false)
    {:halted, %{state | completed: MapSet.put(state.completed, issue_id)}}
  end

  defp violation_comment(reason, identifier) do
    """
    ## Gate C violation — issue parked

    The agent's first turn did not include a required header (`## AC Extracted`, `## AC Evidence`, or `## BLOCKED: AC not testable`).

    Reason: #{reason}
    Issue: #{identifier}

    The agent run has been terminated and the issue moved to a parked state for human review. To re-dispatch, sharpen the acceptance criteria in the description and move the issue back to the dispatch queue.
    """
  end
end
