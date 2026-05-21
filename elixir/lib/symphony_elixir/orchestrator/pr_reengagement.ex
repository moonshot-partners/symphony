defmodule SymphonyElixir.Orchestrator.PrReengagement do
  @moduledoc """
  SYM-16 auto re-engagement loop, capped at K=1 per PR.

  `run/2` walks `state.completed`, refreshes the issue payloads through
  the injected `:issue_fetch_fn`, and for each issue that carries a
  fresh `claude-pr-review: request_changes` verdict on its PR (decided
  by the injected `:detector_fn`) it either:

    * DISPATCH (count == 0) — increments `state.pr_engagements[pr_url].count`
      to 1, removes the id from `state.completed`, transitions the issue
      back to the configured `:pickup_state` so DispatchGate re-picks it
      on the next tick, and posts a threaded workpad comment.

    * CAP-HIT (count >= 1, new head_sha) — transitions the issue to the
      configured `:reject_state`, posts a threaded cap-hit comment, and
      records the head_sha in `cap_hit_shas` so the same sha never
      produces a second comment.

    * CAP-HIT DEDUP (count >= 1, head_sha already in cap_hit_shas) —
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

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.State

  @cap_k 1

  @type opts :: %{
          required(:issue_fetch_fn) => ([String.t()] -> {:ok, [Issue.t()]} | {:error, term()}),
          required(:detector_fn) => (Issue.t() -> term()),
          required(:state_transition_fn) => (Issue.t(), String.t() -> :ok),
          required(:comment_fn) => (String.t(), String.t(), String.t() | nil -> term()),
          required(:pickup_state) => String.t(),
          required(:reject_state) => String.t() | nil
        }

  @doc """
  Walk `state.completed`, decide per-issue whether to re-engage or cap-hit,
  and return the updated `%State{}`.
  """
  @spec run(State.t(), opts()) :: State.t()
  def run(%State{} = state, opts) when is_map(opts) do
    completed_ids = MapSet.to_list(state.completed)

    if completed_ids == [] do
      state
    else
      issue_fetch_fn = Map.fetch!(opts, :issue_fetch_fn)

      case issue_fetch_fn.(completed_ids) do
        {:ok, issues} when is_list(issues) ->
          reengage_issues(state, issues, opts)

        {:error, reason} ->
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
        state

      pr_url ->
        detector_fn = Map.fetch!(opts, :detector_fn)

        case detector_fn.(issue) do
          {:critical, info} when is_map(info) ->
            handle_critical(state, issue, pr_url, info, opts)

          _ ->
            state
        end
    end
  end

  defp reengage_issue(state, _issue, _opts), do: state

  defp handle_critical(state, issue, pr_url, info, opts) do
    engagement = Map.get(state.pr_engagements, pr_url, %{count: 0, cap_hit_shas: MapSet.new()})
    head_sha = Map.get(info, :head_sha, "")

    cond do
      engagement.count < @cap_k ->
        dispatch_reengagement(state, issue, pr_url, info, engagement, opts)

      MapSet.member?(engagement.cap_hit_shas, head_sha) ->
        # Already cap-hit on this exact sha — stay silent, no state churn.
        state

      true ->
        cap_hit(state, issue, pr_url, info, engagement, opts)
    end
  end

  defp dispatch_reengagement(state, %Issue{} = issue, pr_url, info, engagement, opts) do
    state_transition_fn = Map.fetch!(opts, :state_transition_fn)
    comment_fn = Map.fetch!(opts, :comment_fn)
    pickup_state = Map.fetch!(opts, :pickup_state)

    state_transition_fn.(issue, pickup_state)
    parent_id = Map.get(state.workpads, issue.id)
    _ = comment_fn.(issue.id, dispatch_body(info), parent_id)

    %{
      state
      | completed: MapSet.delete(state.completed, issue.id),
        pr_engagements:
          Map.put(state.pr_engagements, pr_url, %{
            count: engagement.count + 1,
            cap_hit_shas: engagement.cap_hit_shas
          })
    }
  end

  defp cap_hit(state, %Issue{} = issue, pr_url, info, engagement, opts) do
    state_transition_fn = Map.fetch!(opts, :state_transition_fn)
    comment_fn = Map.fetch!(opts, :comment_fn)
    reject_state = Map.fetch!(opts, :reject_state)
    head_sha = Map.get(info, :head_sha, "")

    if is_binary(reject_state) and reject_state != "" do
      state_transition_fn.(issue, reject_state)
    end

    parent_id = Map.get(state.workpads, issue.id)
    _ = comment_fn.(issue.id, cap_hit_body(info), parent_id)

    %{
      state
      | pr_engagements:
          Map.put(state.pr_engagements, pr_url, %{
            count: engagement.count,
            cap_hit_shas: MapSet.put(engagement.cap_hit_shas, head_sha)
          })
    }
  end

  defp pr_url_for(%Issue{repos: repos}) when is_list(repos) do
    Enum.find_value(repos, fn
      %{pr: %{url: url}} when is_binary(url) -> url
      _ -> nil
    end)
  end

  defp pr_url_for(_), do: nil

  defp dispatch_body(info) do
    count = Map.get(info, :count, 0)
    items = Map.get(info, :items, [])

    """
    Auto re-engaging agent — claude-pr-review flagged #{count} critical issue(s).

    #{format_items(items)}

    Counter K=1: this is the only automatic re-engagement that will fire on this PR. Next critical verdict on the same PR will park the issue for human review.
    """
  end

  defp cap_hit_body(info) do
    count = Map.get(info, :count, 0)
    head_sha = Map.get(info, :head_sha, "")
    items = Map.get(info, :items, [])

    """
    Cap reached (K=1) — claude-pr-review still flagging #{count} critical issue(s) on commit `#{head_sha}`.

    #{format_items(items)}

    Parking for human review. Push a new commit to clear the alarm or close the loop manually.
    """
  end

  defp format_items([]), do: "(no items listed)"

  defp format_items(items) when is_list(items) do
    Enum.map_join(items, "\n", fn item -> "- " <> to_string(item) end)
  end
end
