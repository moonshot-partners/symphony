defmodule SymphonyElixir.Orchestrator.PromoteToStaging do
  @moduledoc """
  Reconciler for the operator-triggered promote-to-staging flow (SYM-9).

  When a non-technical operator moves a Linear issue to the state configured
  as `tracker.on_promote_state`, this module sweeps each tick and:

  * **All-green CI + clean `claude-pr-review`** → squash-merge the PR
    via `gh pr merge`, then transition the issue to `on_pr_merge_state`
    (e.g. "Ready for QA").
  * **Red CI** → comment the failing check names, transition back to
    `on_complete_state` ("In Code Review") so the operator and agent
    re-engagement path see it.
  * **`claude-pr-review` requested changes** → comment, transition back
    to `on_complete_state`.
  * **CI pending** → no-op; re-check next tick.
  * **No PR attached** → comment, transition to `on_complete_state`.
  * **Multiple PRs attached** → comment that multi-repo promote is not
    supported (SYM-12a), transition to `on_complete_state`. YAGNI until
    a real multi-repo ticket asks for it.

  No-op when any of `on_promote_state`, `on_complete_state`, or
  `on_pr_merge_state` is missing from `Config`. Injection points
  (`fetch_fn`, `status_check_fn`, `review_check_fn`, `merge_fn`,
  `transition_fn`, `comment_fn`) keep the module testable without shims.
  """

  require Logger

  alias SymphonyElixir.{Config, GitHubPr, Tracker}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.{PrUrl, StateTransition}

  @type merge_result :: :ok | {:error, term()}

  @doc """
  Default `gh pr merge --squash` shell-out. Returns `:ok` on exit 0,
  `{:error, output}` otherwise. Tests inject a stub via `:merge_fn`.
  """
  @spec merge!(String.t()) :: merge_result()
  def merge!(pr_url) when is_binary(pr_url) do
    case PrUrl.parse(pr_url) do
      {:ok, owner, repo, number} ->
        case System.cmd(
               "gh",
               ["pr", "merge", "#{number}", "--repo", "#{owner}/#{repo}", "--squash"],
               stderr_to_stdout: true
             ) do
          {_output, 0} ->
            :ok

          {output, code} ->
            {:error, "gh pr merge exit=#{code} output=#{String.trim(output)}"}
        end

      :error ->
        {:error, :invalid_pr_url}
    end
  end

  def merge!(_), do: {:error, :invalid_pr_url}

  @spec reconcile(keyword()) :: :ok
  def reconcile(opts \\ []) do
    tracker = Config.settings!().tracker
    on_promote = tracker.on_promote_state
    on_complete = tracker.on_complete_state
    on_pr_merge = tracker.on_pr_merge_state

    if is_binary(on_promote) and is_binary(on_complete) and is_binary(on_pr_merge) do
      fetch_fn = Keyword.get(opts, :fetch_fn, fn -> Tracker.fetch_issues_by_states([on_promote]) end)
      status_check_fn = Keyword.get(opts, :status_check_fn, &GitHubPr.required_checks_status/1)
      review_check_fn = Keyword.get(opts, :review_check_fn, &GitHubPr.critical_review_pending?/1)
      merge_fn = Keyword.get(opts, :merge_fn, &__MODULE__.merge!/1)
      transition_fn = Keyword.get(opts, :transition_fn, &StateTransition.apply/2)
      comment_fn = Keyword.get(opts, :comment_fn, &Tracker.create_comment/2)

      do_reconcile(
        %{on_complete: on_complete, on_pr_merge: on_pr_merge},
        fetch_fn,
        status_check_fn,
        review_check_fn,
        merge_fn,
        transition_fn,
        comment_fn
      )
    end

    :ok
  end

  defp do_reconcile(targets, fetch_fn, status_check_fn, review_check_fn, merge_fn, transition_fn, comment_fn) do
    case fetch_fn.() do
      {:ok, issues} ->
        Enum.each(issues, fn issue ->
          decide(issue, targets, status_check_fn, review_check_fn, merge_fn, transition_fn, comment_fn)
        end)

      {:error, reason} ->
        Logger.debug("PromoteToStaging.reconcile: fetch failed #{inspect(reason)}")
    end
  end

  defp decide(%Issue{} = issue, targets, status_check_fn, review_check_fn, merge_fn, transition_fn, comment_fn) do
    case pr_urls(issue) do
      [] ->
        park(issue, targets.on_complete, "no PR attached to this issue — cannot promote.", transition_fn, comment_fn)

      [_, _ | _] = urls ->
        body =
          "multiple PRs attached (#{Enum.join(urls, ", ")}); multi-repo promote is not supported yet (see SYM-12a)."

        park(issue, targets.on_complete, body, transition_fn, comment_fn)

      [pr_url] ->
        evaluate_single(issue, pr_url, targets, status_check_fn, review_check_fn, merge_fn, transition_fn, comment_fn)
    end
  end

  defp decide(_issue, _targets, _scfn, _rcfn, _mfn, _tfn, _cfn), do: :ok

  defp evaluate_single(issue, pr_url, targets, status_check_fn, review_check_fn, merge_fn, transition_fn, comment_fn) do
    case status_check_fn.(issue) do
      :pending ->
        Logger.debug("PromoteToStaging: CI pending for #{issue.identifier}; deferring")
        :ok

      {:red, names} ->
        body = "CI is red; failing checks: #{Enum.join(names, ", ")}. Fix and re-promote."
        park(issue, targets.on_complete, body, transition_fn, comment_fn)

      :all_green ->
        case review_check_fn.(issue) do
          {:critical, _info} ->
            body = "claude-pr-review requested changes on the latest commit. Address them and re-promote."
            park(issue, targets.on_complete, body, transition_fn, comment_fn)

          :none ->
            attempt_merge(issue, pr_url, targets, merge_fn, transition_fn, comment_fn)
        end
    end
  end

  defp attempt_merge(issue, pr_url, targets, merge_fn, transition_fn, comment_fn) do
    case merge_fn.(pr_url) do
      :ok ->
        Logger.info("PromoteToStaging: merged #{pr_url} for #{issue.identifier} → #{targets.on_pr_merge}")
        Task.start(fn -> transition_fn.(issue, targets.on_pr_merge) end)
        :ok

      {:error, reason} ->
        body = "PR merge failed (#{inspect(reason)}). Manual intervention needed."
        park(issue, targets.on_complete, body, transition_fn, comment_fn)
    end
  end

  defp park(%Issue{} = issue, target_state, body, transition_fn, comment_fn) do
    Logger.info("PromoteToStaging: parking #{issue.identifier} → #{target_state} (#{body})")
    Task.start(fn -> comment_fn.(issue.id, body) end)
    Task.start(fn -> transition_fn.(issue, target_state) end)
    :ok
  end

  defp pr_urls(%Issue{repos: repos}) when is_list(repos) do
    repos
    |> Enum.map(fn repo -> get_in(repo, [:pr, :url]) end)
    |> Enum.filter(&is_binary/1)
  end

  defp pr_urls(_), do: []
end
