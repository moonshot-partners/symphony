defmodule SymphonyElixir.Orchestrator.PrMerge do
  @moduledoc """
  Helpers for detecting and acting on merged GitHub pull requests linked
  to a Linear issue.

  Extracted from `SymphonyElixir.Orchestrator` so the merge-check and the
  conditional state-transition logic are testable without `*_for_test`
  shims. The orchestrator's `defp reconcile_pr_merged_issues/1` still
  fetches the candidate issues and supplies the default `transition_fn`;
  this module owns the leaf behaviour.
  """

  require Logger

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.PrUrl

  @doc """
  Returns `true` when `gh pr view <number> --repo <owner>/<repo> --json merged`
  reports the PR as merged. Any other shell result, parse failure, or non-binary
  input returns `false`.

  Used as the default `pr_check_fn` for `maybe_transition/3` — callers can
  override it (tests supply a constant function to skip the shell-out).
  """
  @spec merged?(term()) :: boolean()
  def merged?(pr_url) when is_binary(pr_url) do
    case PrUrl.parse(pr_url) do
      {:ok, owner, repo, number} ->
        case System.cmd(
               "gh",
               ["pr", "view", "#{number}", "--repo", "#{owner}/#{repo}", "--json", "merged", "--jq", ".merged"],
               stderr_to_stdout: true
             ) do
          {"true\n", 0} -> true
          _ -> false
        end

      :error ->
        false
    end
  end

  def merged?(_), do: false

  @doc """
  Transitions an issue's state when any of its PR URLs is reported merged by
  `pr_check_fn`. The state change itself is delegated to `transition_fn`,
  which receives `{issue, on_merge_state}` and is invoked asynchronously
  inside `Task.start/1` — matching the orchestrator's pre-refactor behaviour.

  No-op when the issue carries no PR URLs, when none of them pass
  `pr_check_fn`, or when `on_merge_state` is not a binary.
  """
  @spec maybe_transition(
          Issue.t(),
          String.t() | nil,
          (String.t() -> boolean()),
          (Issue.t(), String.t() -> any())
        ) :: :ok
  def maybe_transition(%Issue{} = issue, on_merge_state, pr_check_fn, transition_fn)
      when is_function(pr_check_fn, 1) and is_function(transition_fn, 2) do
    pr_urls =
      issue.repos
      |> Enum.map(fn repo -> get_in(repo, [:pr, :url]) end)
      |> Enum.filter(&is_binary/1)

    if Enum.any?(pr_urls, pr_check_fn) do
      Logger.info("PR merged for #{issue.identifier}; transitioning to #{on_merge_state}")
      Task.start(fn -> transition_fn.(issue, on_merge_state) end)
    end

    :ok
  end
end
