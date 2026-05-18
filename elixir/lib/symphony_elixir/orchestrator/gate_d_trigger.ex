defmodule SymphonyElixir.Orchestrator.GateDTrigger do
  @moduledoc """
  Runs Gate D at the end of a successful agent session, validating that
  the final turn contains an `## AC Evidence` section.

  Only fires when `gate_c_checked` is true — meaning the agent posted at
  least one turn during the session. Skipped for sessions that exited
  before the first turn was recorded.

  Returns `:ok | {:violation, reason}` so the caller can post a tracker
  comment without this module performing I/O.
  """

  alias SymphonyElixir.GateD

  @type result :: :ok | {:violation, :missing_header | :empty_message}

  @spec maybe_run(map()) :: result()
  def maybe_run(running_entry) do
    if Map.get(running_entry, :gate_c_checked) do
      case GateD.validate_final_turn(Map.get(running_entry, :last_agent_text)) do
        :ok ->
          :ok

        {:violation, _} = violation ->
          GateD.log_violation(violation, running_entry)
          violation
      end
    else
      :ok
    end
  end
end
