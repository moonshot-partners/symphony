defmodule SymphonyElixir.Orchestrator.DispatchGate do
  @moduledoc """
  Pure issue-level eligibility filters for orchestrator dispatch.

  Extracted from `SymphonyElixir.Orchestrator` (CP7): no State struct, no
  GenServer state, no callbacks. Capacity gates (available slots, worker
  slots) stay in the orchestrator and compose these predicates at the
  callsite.

  Behaviour preserved byte-for-byte from the in-orchestrator helpers:
  `candidate_issue?/3`, `has_pr_attachment?/1`, `issue_routable_to_worker?/1`,
  `todo_issue_blocked_by_non_terminal?/2`, `terminal_issue_state?/2`,
  `active_issue_state?/2`, `normalize_issue_state/1`, `terminal_state_set/0`,
  `active_state_set/0`, `retry_candidate_issue?/2`,
  `revalidate_issue_for_dispatch/3`.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @spec terminal_state_set() :: MapSet.t()
  def terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  @spec active_state_set() :: MapSet.t()
  def active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  @spec normalize_state(String.t()) :: String.t()
  def normalize_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  @spec terminal_state?(String.t(), MapSet.t()) :: boolean()
  def terminal_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_state(state_name))
  end

  def terminal_state?(_state_name, _terminal_states), do: false

  @spec active_state?(String.t(), MapSet.t()) :: boolean()
  def active_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_state(state_name))
  end

  def active_state?(_state_name, _active_states), do: false

  @spec has_pr_attachment?(Issue.t() | term()) :: boolean()
  def has_pr_attachment?(%Issue{has_pr_attachment: true}), do: true
  def has_pr_attachment?(_), do: false

  @spec routable_to_worker?(Issue.t() | term()) :: boolean()
  def routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
      when is_boolean(assigned_to_worker),
      do: assigned_to_worker

  def routable_to_worker?(_issue), do: true

  @spec todo_blocked_by_non_terminal?(Issue.t() | term(), MapSet.t()) :: boolean()
  def todo_blocked_by_non_terminal?(
        %Issue{state: issue_state, blocked_by: blockers},
        terminal_states
      )
      when is_binary(issue_state) and is_list(blockers) do
    normalize_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  def todo_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  @spec candidate?(Issue.t() | term(), MapSet.t(), MapSet.t()) :: boolean()
  def candidate?(
        %Issue{
          id: id,
          identifier: identifier,
          title: title,
          state: state_name
        } = issue,
        active_states,
        terminal_states
      )
      when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    routable_to_worker?(issue) and
      active_state?(state_name, active_states) and
      !terminal_state?(state_name, terminal_states)
  end

  def candidate?(_issue, _active_states, _terminal_states), do: false

  @spec retry_candidate?(Issue.t() | term(), MapSet.t()) :: boolean()
  def retry_candidate?(%Issue{} = issue, terminal_states) do
    candidate?(issue, active_state_set(), terminal_states) and
      !todo_blocked_by_non_terminal?(issue, terminal_states)
  end

  def retry_candidate?(_issue, _terminal_states), do: false

  @spec revalidate(Issue.t() | term(), ([String.t()] -> term()), MapSet.t()) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate(%Issue{id: issue_id}, issue_fetcher, terminal_states)
      when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def revalidate(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}
end
