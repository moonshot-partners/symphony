defmodule SymphonyElixir.Orchestrator.PrReengagement do
  @moduledoc """
  SYM-16 auto re-engagement loop, capped at K=2 per PR.

  `run/2` walks `state.completed`, refreshes the issue payloads through
  the injected `:issue_fetch_fn`, and for each issue that carries fresh
  blocking PR-review feedback on its PR (decided by the injected
  `:detector_fn`) it either:

    * DISPATCH (count < 2) — increments `state.pr_engagements[pr_url].count`,
      removes the id from `state.completed`, transitions the issue back to
      the configured `:pickup_state` so DispatchGate re-picks it on the next
      tick, and posts a threaded workpad comment.

    * CAP-IGNORE (count >= 2, new head_sha) — leaves Linear untouched and
      records the head_sha in `cap_hit_shas` so the same sha never produces
      a second decision-log event.

    * CAP-IGNORE DEDUP (count >= 2, head_sha already in cap_hit_shas) —
      no state transition, no comment. Idempotent across poll cycles.

  All Linear / GitHub side-effects are injected so the module stays
  pure-transform under test. The orchestrator wires the production
  callbacks in `reconcile_running_issues/1` (CP… for SYM-16).

  ## Why the loop iterates `state.completed`, not `state.running`

  WorkpadPrSync terminates the agent and lands the issue in
  `state.completed` the moment the PR becomes ready (MERGED or
  OPEN+CI-green). The critical-review comment may arrive minutes later,
  after the agent already walked away. The loop has to look at the
  completed set so the re-engagement can still find the work.
  """

  require Logger

  alias SymphonyElixir.DecisionLog
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.State

  @cap_k 2

  @type opts :: %{
          required(:issue_fetch_fn) => ([String.t()] -> {:ok, [Issue.t()]} | {:error, term()}),
          required(:detector_fn) => (Issue.t() -> term()),
          required(:state_transition_fn) => (Issue.t(), String.t() -> :ok),
          required(:comment_fn) => (String.t(), String.t(), String.t() | nil -> term()),
          required(:pickup_state) => String.t(),
          optional(:reject_state) => String.t() | nil
        }

  @doc """
  Walk `state.completed`, decide per-issue whether to re-engage or ignore overflow,
  and return the updated `%State{}`.
  """
  @spec run(State.t(), opts()) :: State.t()
  def run(%State{} = state, opts) when is_map(opts) do
    completed_ids = MapSet.to_list(state.completed)

    DecisionLog.emit("pr_reengagement.run", %{
      completed_size: length(completed_ids),
      completed_ids: completed_ids,
      pr_engagement_keys: Map.keys(state.pr_engagements)
    })

    if completed_ids == [] do
      state
    else
      issue_fetch_fn = Map.fetch!(opts, :issue_fetch_fn)

      case issue_fetch_fn.(completed_ids) do
        {:ok, issues} when is_list(issues) ->
          reengage_issues(state, issues, opts)

        {:error, reason} ->
          DecisionLog.emit("pr_reengagement.fetch_error", %{
            reason: inspect(reason),
            completed_ids: completed_ids
          })

          Logger.debug("PrReengagement: issue_fetch_fn failed: #{inspect(reason)}; skipping cycle")
          state
      end
    end
  end

  defp reengage_issues(state, issues, opts) do
    Enum.reduce(issues, state, fn issue, state_acc -> reengage_issue(state_acc, issue, opts) end)
  end

  # If the issue carries no PR url we cannot reason about engagements;
  # the loop short-circuits before invoking the detector.
  defp reengage_issue(%State{} = state, %Issue{} = issue, opts) do
    case pr_url_for(issue) do
      nil ->
        DecisionLog.emit("pr_reengagement.skip_no_pr", %{
          issue_id: issue.id,
          identifier: issue.identifier
        })

        state

      pr_url ->
        detector_fn = Map.fetch!(opts, :detector_fn)

        case detector_fn.(issue) do
          {:critical, info} when is_map(info) ->
            handle_critical(state, issue, critical_pr_url(info, pr_url), info, opts)

          verdict ->
            DecisionLog.emit("pr_reengagement.skip_no_critical", %{
              issue_id: issue.id,
              identifier: issue.identifier,
              pr_url: pr_url,
              verdict: inspect(verdict)
            })

            state
        end
    end
  end

  defp handle_critical(state, issue, pr_url, info, opts) do
    engagement = Map.get(state.pr_engagements, pr_url, %{count: 0, cap_hit_shas: MapSet.new()})
    head_sha = Map.get(info, :head_sha, "")

    cond do
      engagement.count < @cap_k ->
        dispatch_reengagement(state, issue, pr_url, info, engagement, opts)

      MapSet.member?(engagement.cap_hit_shas, head_sha) ->
        # Already ignored on this exact sha — stay silent, no state churn.
        DecisionLog.emit("pr_reengagement.cap_ignore_dedup", %{
          issue_id: issue.id,
          identifier: issue.identifier,
          pr_url: pr_url,
          head_sha: head_sha,
          count: engagement.count
        })

        state

      true ->
        ignore_cap_overflow(state, issue, pr_url, info, engagement)
    end
  end

  defp dispatch_reengagement(state, %Issue{} = issue, pr_url, info, engagement, opts) do
    state_transition_fn = Map.fetch!(opts, :state_transition_fn)
    comment_fn = Map.fetch!(opts, :comment_fn)
    pickup_state = Map.fetch!(opts, :pickup_state)

    state_transition_fn.(issue, pickup_state)
    parent_id = Map.get(state.workpads, issue.id)
    next_count = engagement.count + 1
    _ = comment_fn.(issue.id, dispatch_body(info, next_count), parent_id)

    DecisionLog.emit("pr_reengagement.dispatch", %{
      issue_id: issue.id,
      identifier: issue.identifier,
      pr_url: pr_url,
      head_sha: Map.get(info, :head_sha, ""),
      critical_count: Map.get(info, :count, 0),
      pickup_state: pickup_state,
      next_count: next_count
    })

    %{
      state
      | completed: MapSet.delete(state.completed, issue.id),
        pr_engagements:
          Map.put(state.pr_engagements, pr_url, %{
            count: next_count,
            cap_hit_shas: engagement.cap_hit_shas
          })
    }
  end

  defp ignore_cap_overflow(state, %Issue{} = issue, pr_url, info, engagement) do
    head_sha = Map.get(info, :head_sha, "")

    DecisionLog.emit("pr_reengagement.cap_ignore", %{
      issue_id: issue.id,
      identifier: issue.identifier,
      pr_url: pr_url,
      head_sha: head_sha,
      critical_count: Map.get(info, :count, 0),
      action: "ignore",
      count: engagement.count
    })

    %{
      state
      | pr_engagements:
          Map.put(state.pr_engagements, pr_url, %{
            count: engagement.count,
            cap_hit_shas: MapSet.put(engagement.cap_hit_shas, head_sha)
          })
    }
  end

  defp critical_pr_url(info, fallback) do
    case Map.get(info, :pr_url) do
      pr_url when is_binary(pr_url) and pr_url != "" -> pr_url
      _ -> fallback
    end
  end

  defp pr_url_for(%Issue{repos: repos}) when is_list(repos) do
    Enum.find_value(repos, fn
      %{pr: %{url: url}} when is_binary(url) -> url
      _ -> nil
    end)
  end

  defp dispatch_body(info, next_count) do
    count = Map.get(info, :count, 0)
    items = Map.get(info, :items, [])

    """
    Auto re-engaging agent — PR review gate requested changes#{critical_count_suffix(count)}.

    #{format_items(items)}

    Counter K=#{@cap_k}: automatic re-engagement #{next_count} of #{@cap_k}. Further blocking verdicts on this PR will be ignored by Symphony and left in the PR review thread.
    """
  end

  defp format_items([]), do: "(no items listed)"

  defp format_items(items) when is_list(items) do
    Enum.map_join(items, "\n", fn item -> "- " <> to_string(item) end)
  end

  defp critical_count_suffix(count) when is_integer(count) and count > 0,
    do: " (#{count} critical issue(s))"

  defp critical_count_suffix(_), do: " (0 critical issues; see the PR review comment)"
end
