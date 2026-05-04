defmodule SymphonyElixir.Orchestrator.IssueFilter do
  @moduledoc """
  Pure helpers that decide which Linear issues are eligible for
  dispatch and in what order. Extracted from Orchestrator to keep
  the GenServer file focused on state transitions and supervision.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @spec sort_issues_for_dispatch([Issue.t() | term()]) :: [Issue.t() | term()]
  def sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue),
         issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  @spec candidate_issue?(Issue.t() | term(), MapSet.t(), MapSet.t()) :: boolean()
  def candidate_issue?(
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
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  def candidate_issue?(_issue, _active_states, _terminal_states), do: false

  @spec todo_issue_blocked_by_non_terminal?(Issue.t() | term(), MapSet.t()) :: boolean()
  def todo_issue_blocked_by_non_terminal?(
        %Issue{state: issue_state, blocked_by: blockers},
        terminal_states
      )
      when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  def todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  @spec terminal_issue_state?(term(), MapSet.t()) :: boolean()
  def terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  def terminal_issue_state?(_state_name, _terminal_states), do: false

  @spec active_issue_state?(term(), MapSet.t()) :: boolean()
  def active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  @spec terminal_state_set() :: MapSet.t()
  def terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  @spec active_state_set() :: MapSet.t()
  def active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  @spec issue_routable_to_worker?(Issue.t() | term()) :: boolean()
  def issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
      when is_boolean(assigned_to_worker),
      do: assigned_to_worker

  def issue_routable_to_worker?(_issue), do: true

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807
end
