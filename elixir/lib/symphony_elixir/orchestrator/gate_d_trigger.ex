defmodule SymphonyElixir.Orchestrator.GateDTrigger do
  @moduledoc """
  Runs Gate D at the end of a successful agent session, validating that
  the final turn contains an `## AC Evidence` section.

  Only fires when `gate_c_checked` is true — meaning the agent posted at
  least one turn during the session. Skipped for sessions that exited
  before the first turn was recorded.

  Returns `:ok | {:violation, reason}` so the caller can post a tracker
  comment without this module performing I/O.

  ## Why the `:pinned_artifacts` short-circuit

  `running_entry.last_agent_text` holds only the agent's *latest*
  message. An agent that posts `## AC Evidence` mid-session and then
  emits a closing wrap-up sentence leaves that wrap-up in
  `last_agent_text` by the time the `:DOWN` handler runs Gate D — the
  evidence block has scrolled past. Validating the slice alone would
  false-flag a compliant run (the SODEV-891 bug class, first seen on
  Gate C).

  `ArtifactPin` snapshots the `## AC Evidence` section into a durable
  tracker comment the moment it appears and records `"AC Evidence"` in
  `running_entry.pinned_artifacts`. That marker is the authoritative
  proof the evidence was produced — when present, Gate D trusts it and
  skips the stale-slice check entirely.
  """

  alias SymphonyElixir.GateD

  @type result :: :ok | {:violation, :missing_header | :empty_message}

  @spec maybe_run(map()) :: result()
  def maybe_run(running_entry) do
    cond do
      not Map.get(running_entry, :gate_c_checked, false) ->
        :ok

      ac_evidence_pinned?(running_entry) ->
        :ok

      true ->
        case GateD.validate_final_turn(Map.get(running_entry, :last_agent_text)) do
          :ok ->
            :ok

          {:violation, _} = violation ->
            GateD.log_violation(violation, running_entry)
            violation
        end
    end
  end

  defp ac_evidence_pinned?(running_entry) do
    case Map.get(running_entry, :pinned_artifacts) do
      %MapSet{} = set -> MapSet.member?(set, "AC Evidence")
      _ -> false
    end
  end
end
