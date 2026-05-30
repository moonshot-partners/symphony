defmodule SymphonyElixir.Orchestrator.AgentExit do
  @moduledoc """
  Handles `:DOWN` messages from supervised agent tasks. Sibling to
  `Reconcile` / `PrReengagement` — same intent, fires when an agent
  process exits (normal completion or crash).

  `process_exit/4` is the single API. Given the orchestrator state,
  the `:DOWN` ref, the exit reason, and a set of injected callbacks,
  it pops the matching running entry, records session completion,
  and either:

    * dispatches the `:normal` continuation path (Gate D trigger,
      `completer` callback, continuation retry scheduling), or
    * dispatches the crash path (failure metadata, `RetryAttempts`
      schedule, `retrier` callback).

  Tracker side effects (Gate D violation comments, retry-cap comments
  from the retrier) run inside `Task.Supervisor.start_child` so the
  orchestrator process is never blocked on Tracker I/O.
  """

  require Logger

  alias SymphonyElixir.Orchestrator.{
    AgentTotals,
    ArtifactPin,
    RetryAttempts,
    RetryDispatch,
    RetryPlan,
    RunLedgerHook,
    RunningEntry,
    State
  }

  @type completer :: (State.t(), String.t() -> State.t())
  @type retrier :: ({:armed | :halted, State.t()}, term(), String.t(), map() -> State.t())

  @type opts :: [
          completer: completer(),
          retrier: retrier(),
          retry_dispatch_opts: map(),
          recipient: pid()
        ]

  @spec process_exit(State.t(), reference(), term(), opts()) :: State.t()
  def process_exit(%State{running: running} = state, ref, reason, opts) when is_list(opts) do
    case RunningEntry.find_id_for_ref(running, ref) do
      nil ->
        state

      issue_id ->
        handle_exit(state, issue_id, reason, opts)
    end
  end

  defp handle_exit(state, issue_id, reason, opts) do
    {running_entry, state} = RunningEntry.pop(state, issue_id)
    state = AgentTotals.record_session_completion(state, running_entry)
    RunLedgerHook.record(running_entry, issue_id)
    session_id = RunningEntry.session_id(running_entry)

    state = dispatch_reason(state, issue_id, reason, running_entry, session_id, opts)

    Logger.info(
      "Agent task finished for issue_id=#{issue_id} session_id=#{session_id} " <>
        "reason=#{inspect(reason)} " <> RunningEntry.format_token_totals(running_entry)
    )

    state
  end

  defp dispatch_reason(state, issue_id, :normal, running_entry, session_id, opts) do
    Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

    completer = Keyword.fetch!(opts, :completer)
    retry_dispatch_opts = Keyword.fetch!(opts, :retry_dispatch_opts)

    pinned_entry = ArtifactPin.pin(running_entry, issue_id, "AC Evidence")

    state
    |> completer.(issue_id)
    |> RetryDispatch.maybe_schedule_continuation_retry(issue_id, pinned_entry, retry_dispatch_opts)
  end

  defp dispatch_reason(state, issue_id, reason, running_entry, session_id, opts) do
    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

    retrier = Keyword.fetch!(opts, :retrier)
    recipient = Keyword.fetch!(opts, :recipient)

    next_attempt = RetryPlan.next_attempt_from_running(running_entry)

    failure_metadata = %{
      identifier: running_entry.identifier,
      error: "agent exited: #{inspect(reason)}",
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    }

    RetryAttempts.schedule(state, issue_id, next_attempt, failure_metadata, recipient)
    |> retrier.(Map.get(running_entry, :issue), issue_id, failure_metadata)
  end
end
