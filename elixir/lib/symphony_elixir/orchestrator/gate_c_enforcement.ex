defmodule SymphonyElixir.Orchestrator.GateCEnforcement do
  @moduledoc """
  Soft-gate enforcement for Gate C (AC Extracted) violations during the
  agent's first turn. Sibling to `PreDispatch` — same intent, fires from
  inside an already-running agent session.

  `enforce/5` is the single API:

    * `:ok` → returns `{:continue, state}` and the orchestrator keeps
      the running agent alive.
    * `{:violation, reason}` → records a diagnostic summary in the optional
      operational view and keeps the agent running. Returns
      `{:continue, state}`.

  Gate C used to hard-park issues, but the check is too ritual-sensitive to be
  a production blocker: it can fail even when the agent is capable of finishing
  the ticket. Keep the signal; do not interrupt delivery.
  """

  require Logger

  alias SymphonyElixir.OperationalView
  alias SymphonyElixir.Orchestrator.State

  @type gate_c_result :: :ok | {:violation, atom()}
  @type opts :: keyword()

  @spec enforce(gate_c_result(), State.t(), String.t(), map(), opts()) ::
          {:continue, State.t()}
  def enforce(:ok, %State{} = state, _issue_id, _running_entry, _opts), do: {:continue, state}

  def enforce({:violation, reason}, %State{} = state, issue_id, running_entry, _opts)
      when is_binary(issue_id) and is_map(running_entry) do
    identifier = Map.get(running_entry, :identifier, issue_id)

    Logger.warning("Gate C soft violation: issue_id=#{issue_id} issue_identifier=#{identifier} reason=#{reason}")

    OperationalView.put_run_summary(issue_id, violation_comment(reason, identifier))

    {:continue, state}
  end

  defp violation_comment(reason, identifier) do
    """
    ## Gate C warning

    The agent's first turn did not include a required header (`## AC Extracted`, `## AC Evidence`, or `## BLOCKED: AC not testable`).

    Reason: #{reason}
    Issue: #{identifier}

    The agent run was allowed to continue. This warning is diagnostic only; acceptance should be judged by the final PR, tests, and evidence.
    """
  end
end
