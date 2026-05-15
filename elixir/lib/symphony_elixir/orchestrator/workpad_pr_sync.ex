defmodule SymphonyElixir.Orchestrator.WorkpadPrSync do
  @moduledoc """
  PR-attached side-effect cluster extracted from
  `SymphonyElixir.Orchestrator` (CP19). When the reconcile loop
  detects that the running issue now carries a GitHub PR attachment,
  the orchestrator forwards the running entry here for the workpad
  resync + downstream notifications (Linear state transition,
  GitHub label, QA evidence upload).

  `sync/3` returns the `%State{}` unchanged — the side-effects all
  flow through collaborator modules (`Workpad`, `StateTransition`,
  `GithubLabel`, `QaEvidence`). The orchestrator pid is threaded as
  the `recipient` argument so `Workpad.maybe_sync/3` can callback
  via `send/2` without coupling this module to `self()`.
  """

  alias SymphonyElixir.{Config, QaEvidence, Workpad}
  alias SymphonyElixir.Orchestrator.{GithubLabel, RunningEntry, State, StateTransition}

  @doc """
  Sync the workpad comment for `issue_id` with the `pr_attached`
  event and trigger the downstream PR-attached side-effects.
  Returns the `%State{}` unchanged. No-ops (with state pass-through)
  when the issue is not in `state.running`.
  """
  @spec sync(State.t(), String.t(), pid()) :: State.t()
  def sync(%State{} = state, issue_id, recipient)
      when is_binary(issue_id) and is_pid(recipient) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      running_entry ->
        comment_id =
          Map.get(running_entry, :workpad_comment_id) || Map.get(state.workpads, issue_id)

        entry =
          running_entry
          |> Map.put(:last_agent_event, :pr_attached)
          |> RunningEntry.put_workpad_comment_id(comment_id)

        update = %{event: :pr_attached, timestamp: DateTime.utc_now()}
        _ = Workpad.maybe_sync(entry, update, recipient)

        run_side_effects(Map.get(running_entry, :issue), running_entry)

        state
    end
  end

  defp run_side_effects(nil, _running_entry), do: :ok

  defp run_side_effects(issue, running_entry) do
    StateTransition.apply(issue, Config.settings!().tracker.on_complete_state)
    Task.start(fn -> GithubLabel.apply(issue) end)

    QaEvidence.maybe_publish(
      Map.get(issue, :id),
      Map.get(running_entry, :workspace_path)
    )

    :ok
  end
end
