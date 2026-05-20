defmodule SymphonyElixir.Orchestrator.GateCTrigger do
  @moduledoc """
  Runs Gate C on the first turn of an agent session and marks the running
  entry so subsequent updates skip re-validation.

  Extracted from `SymphonyElixir.Orchestrator` (CP6): pure helper over the
  `running_entry` map — no GenServer state, no callbacks.

  Returns `{:ok | {:violation, reason}, updated_running_entry}` so callers
  can act on violations (e.g. post a tracker comment) without this module
  performing I/O.

  ## Why the `:pinned_artifacts` short-circuit

  `running_entry.last_agent_text` only ever holds the agent's *latest*
  message (see `Workpad.update_last_agent_text/2` — `:turn_completed` is
  not an `item/agent_message`, so it never refreshes the field). On a
  single-session autonomous run the agent posts `## AC Extracted` mid-turn
  and ends with a `## AC Evidence` / `## Summary` wrap-up; by the time the
  `:turn_completed` event reaches Gate C the field has rolled past the AC
  block. Validating it then false-halts a run that did everything right.

  `ArtifactPin` already snapshots the `## AC Extracted` block into a
  durable tracker comment the instant it appears, recording the header in
  `running_entry.pinned_artifacts`. That set is the authoritative record
  of "the agent engaged the AC contract" — when it carries `AC Extracted`
  Gate C trusts it and skips the stale-text check entirely.
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

      ac_extracted_pinned?(running_entry) ->
        {:ok, Map.put(running_entry, :gate_c_checked, true)}

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

  defp ac_extracted_pinned?(running_entry) do
    case Map.get(running_entry, :pinned_artifacts) do
      %MapSet{} = set -> MapSet.member?(set, "AC Extracted")
      _ -> false
    end
  end
end
