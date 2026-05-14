defmodule SymphonyElixir.Orchestrator.Dispatch do
  @moduledoc """
  Pure helpers for the orchestrator's dispatch ordering.

  Extracted from `SymphonyElixir.Orchestrator`. The dispatch flow itself
  (claim/release, worker selection, retry timers) still lives in the
  orchestrator GenServer; only the order-of-pickup logic lives here so it
  can be tested without an `*_for_test` shim.

  Sort order is, in this exact precedence:

    1. Linear priority rank (1 highest .. 4 lowest, missing/invalid = 5).
    2. `issue.created_at` ascending (older first), with no-DateTime issues
       sorted last via a sentinel max-integer key.
    3. `issue.identifier || issue.id || ""` as a deterministic tiebreaker.
  """

  alias SymphonyElixir.Linear.Issue

  @no_datetime_sort_key 9_223_372_036_854_775_807

  @doc """
  Sorts issues for dispatch by priority, then age, then identifier.

  Non-Issue elements are placed last with neutral keys; this matches the
  pre-refactor behaviour where `sort_issues_for_dispatch/1` accepted any
  list but only Issues carry the relevant fields.
  """
  @spec sort([Issue.t() | term()]) :: [Issue.t() | term()]
  def sort(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  @doc false
  def priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  def priority_rank(_priority), do: 5

  @doc false
  def issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  def issue_created_at_sort_key(%Issue{}), do: @no_datetime_sort_key
  def issue_created_at_sort_key(_issue), do: @no_datetime_sort_key
end
