defmodule SymphonyElixir.Orchestrator.StateTransition do
  @moduledoc """
  Pushes a Linear issue to a new state via the configured tracker.

  Extracted from `SymphonyElixir.Orchestrator` (CP6): single side effect
  (`Tracker.update_issue_state/2`) plus log. No GenServer coupling.

  `PrMerge.maybe_transition/4` already takes this as a callback (`&apply/2`),
  so the callsite shape is unchanged.
  """

  require Logger
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker

  @spec apply(Issue.t() | term(), String.t() | nil) :: :ok
  def apply(%Issue{} = issue, state_name)
      when is_binary(state_name) and state_name != "" do
    case Tracker.update_issue_state(issue.id, state_name) do
      :ok ->
        Logger.info("Linear state transition: #{issue_context(issue)} → #{state_name}")

      {:error, reason} ->
        Logger.warning("Linear state transition failed: #{issue_context(issue)} → #{state_name}: #{inspect(reason)}")
    end

    :ok
  end

  def apply(_issue, _state_name), do: :ok

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
