defmodule SymphonyElixir.Orchestrator.GateCTrigger do
  @moduledoc """
  Runs Gate C on the first turn of an agent session and marks the running
  entry so subsequent updates skip re-validation.

  Extracted from `SymphonyElixir.Orchestrator` (CP6): pure helper over the
  `running_entry` map — no GenServer state, no callbacks.

  Returns `{:ok | {:violation, reason}, updated_running_entry}` so callers
  can act on violations (e.g. post a tracker comment) without this module
  performing I/O.
  """

  alias SymphonyElixir.GateC

  @type result :: :ok | {:violation, :missing_header | :empty_message}

  @spec maybe_run(map(), map()) :: {result(), map()}
  def maybe_run(running_entry, %{event: :turn_completed}) do
    cond do
      Map.get(running_entry, :gate_c_checked) == true ->
        {:ok, running_entry}

      Map.get(running_entry, :turn_count) != 1 ->
        {:ok, running_entry}

      true ->
        result =
          case GateC.validate_first_turn(Map.get(running_entry, :last_agent_text)) do
            :ok ->
              :ok

            {:violation, _} = violation ->
              GateC.log_violation(violation, running_entry)
              violation
          end

        {result, Map.put(running_entry, :gate_c_checked, true)}
    end
  end

  def maybe_run(running_entry, _update), do: {:ok, running_entry}
end
