defmodule SymphonyElixir.Orchestrator.ProcessLiveness do
  @moduledoc """
  Defense-in-depth scan for `state.running` entries whose worker Task
  PID is no longer alive.

  The orchestrator already monitors every worker via `Process.monitor`
  and reacts to `:DOWN` to clean up. This scan exists as a backstop:
  if the `:DOWN` was lost (rare BEAM scenario, or the PID died
  synchronously before the monitor registered), the entry remains in
  `state.running` pointing at a dead PID and the issue stalls
  silently. Running this scan each tick converts those entries back
  into the normal terminate path.

  Pure module — `Process.alive?/1` is injected so tests can simulate
  dead PIDs without spawning real processes.
  """

  @type running :: %{required(String.t()) => map()}
  @type alive_fn :: (pid() -> boolean())

  @doc """
  Return the issue_ids whose running entry carries a `:pid` that is
  no longer alive. Entries without a PID, or whose `:pid` field is
  not a pid, are skipped — those represent intermediate states
  (entry written before pid assignment) and are not this scan's
  concern.
  """
  @spec dead_issue_ids(running(), alive_fn()) :: [String.t()]
  def dead_issue_ids(running, alive_fn \\ &Process.alive?/1)
      when is_map(running) and is_function(alive_fn, 1) do
    Enum.flat_map(running, fn
      {issue_id, %{pid: pid}} when is_binary(issue_id) and is_pid(pid) ->
        if alive_fn.(pid), do: [], else: [issue_id]

      _ ->
        []
    end)
  end
end
