defmodule SymphonyElixir.Orchestrator.GateCTrigger do
  @moduledoc """
  Runs Gate C on the first turn of an agent session and marks the running
  entry so subsequent updates skip re-validation.

  Extracted from `SymphonyElixir.Orchestrator` (CP6): pure helper over the
  `running_entry` map — no GenServer state, no callbacks.
  """

  alias SymphonyElixir.GateC

  @spec maybe_run(map(), map()) :: map()
  def maybe_run(running_entry, %{event: :turn_completed}) do
    cond do
      Map.get(running_entry, :gate_c_checked) == true ->
        running_entry

      Map.get(running_entry, :turn_count) != 1 ->
        running_entry

      true ->
        case GateC.validate_first_turn(Map.get(running_entry, :last_agent_text)) do
          :ok ->
            :ok

          {:violation, _} = violation ->
            GateC.log_violation(violation, running_entry)
        end

        Map.put(running_entry, :gate_c_checked, true)
    end
  end

  def maybe_run(running_entry, _update), do: running_entry
end
