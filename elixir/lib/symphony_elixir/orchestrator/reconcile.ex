defmodule SymphonyElixir.Orchestrator.Reconcile do
  @moduledoc """
  Running-issue state reconciliation, extracted from
  `SymphonyElixir.Orchestrator` (CP22).

  `run/2` is the single entry point: it fetches the current Linear
  states for every `state.running` issue, decides per-issue whether to
  terminate the agent, sync the workpad after a PR landed, or refresh
  the cached `Issue` payload — and finally terminates any agent whose
  issue is no longer visible.

  Side-effectful operations (terminating an issue's agent task and
  syncing the workpad after a PR attaches) are injected as `:terminate_fn`
  and `:pr_sync_fn` callbacks so the sibling stays pure-transform and
  can be exercised in tests without the surrounding `GenServer`.
  """

  require Logger

  alias SymphonyElixir.{DecisionLog, GitHubPr, Tracker}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.{DispatchGate, RunningEntry, State}

  @type terminate_fn :: (State.t(), String.t(), boolean() -> State.t())
  @type pr_sync_fn :: (State.t(), String.t() -> State.t())
  @type fetch_fn :: ([String.t()] -> {:ok, [Issue.t()]} | {:error, term()})

  @type opts :: %{
          required(:terminate_fn) => terminate_fn(),
          required(:pr_sync_fn) => pr_sync_fn(),
          optional(:fetch_fn) => fetch_fn(),
          optional(:active_states) => MapSet.t(),
          optional(:terminal_states) => MapSet.t()
        }

  @doc """
  Reconcile every `state.running` issue against its current Linear
  state. Returns the updated `%State{}` after any terminations,
  workpad PR syncs, and cached-issue refreshes the reconciliation
  decided.
  """
  @spec run(State.t(), opts()) :: State.t()
  def run(%State{} = state, opts) when is_map(opts) do
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      terminate_fn = Map.fetch!(opts, :terminate_fn)
      pr_sync_fn = Map.fetch!(opts, :pr_sync_fn)
      fetch_fn = Map.get(opts, :fetch_fn, &Tracker.fetch_issue_states_by_ids/1)
      active_states = Map.get(opts, :active_states, DispatchGate.active_state_set())
      terminal_states = Map.get(opts, :terminal_states, DispatchGate.terminal_state_set())

      DecisionLog.emit("reconcile.run", %{
        running_ids: running_ids,
        running_size: length(running_ids)
      })

      case fetch_fn.(running_ids) do
        {:ok, issues} ->
          state
          |> reconcile_running_issue_states(issues, active_states, terminal_states, terminate_fn, pr_sync_fn)
          |> reconcile_missing_running_issue_ids(running_ids, issues, terminate_fn)

        {:error, reason} ->
          DecisionLog.emit("reconcile.fetch_error", %{
            reason: inspect(reason),
            running_ids: running_ids
          })

          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc """
  Apply per-issue reconciliation decisions for a known list of `Issue`
  payloads. Exposed for the existing `reconcile_issue_states_for_test/2`
  shim on `Orchestrator`.
  """
  @spec reconcile_issue_states(State.t(), [Issue.t()], terminate_fn(), pr_sync_fn()) ::
          State.t()
  def reconcile_issue_states(%State{} = state, issues, terminate_fn, pr_sync_fn)
      when is_list(issues) and is_function(terminate_fn, 3) and is_function(pr_sync_fn, 2) do
    reconcile_running_issue_states(
      state,
      issues,
      DispatchGate.active_state_set(),
      DispatchGate.terminal_state_set(),
      terminate_fn,
      pr_sync_fn
    )
  end

  defp reconcile_running_issue_states(state, [], _active, _terminal, _terminate_fn, _pr_sync_fn) do
    state
  end

  defp reconcile_running_issue_states(state, [issue | rest], active, terminal, terminate_fn, pr_sync_fn) do
    new_state = reconcile_issue_state(state, issue, active, terminal, terminate_fn, pr_sync_fn)
    reconcile_running_issue_states(new_state, rest, active, terminal, terminate_fn, pr_sync_fn)
  end

  defp reconcile_issue_state(state, %Issue{} = issue, active, terminal, terminate_fn, pr_sync_fn) do
    cond do
      DispatchGate.terminal_state?(issue.state, terminal) ->
        emit_decision(issue, "terminal_state", "terminate")
        Logger.info("Issue moved to terminal state: #{RunningEntry.format_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_fn.(state, issue.id, true)

      DispatchGate.has_pr_attachment?(issue) and GitHubPr.ready?(issue) ->
        reconcile_ready_pr(state, issue, terminate_fn, pr_sync_fn)

      DispatchGate.has_pr_attachment?(issue) ->
        Logger.debug("Issue has PR attachment(s) but none ready (stale closed, or OPEN with failing/pending CI): #{RunningEntry.format_context(issue)} state=#{issue.state}; keeping agent running")

        if DispatchGate.active_state?(issue.state, active) do
          emit_decision(issue, "has_pr_attachment_active", "refresh")
          refresh_running_issue_state(state, issue)
        else
          emit_decision(issue, "has_pr_attachment_non_active", "terminate")
          Logger.info("Issue moved to non-active state with stale PR: #{RunningEntry.format_context(issue)} state=#{issue.state}; stopping active agent")
          terminate_fn.(state, issue.id, true)
        end

      !DispatchGate.routable_to_worker?(issue) ->
        emit_decision(issue, "not_routable", "terminate")
        Logger.info("Issue no longer routed to this worker: #{RunningEntry.format_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_fn.(state, issue.id, true)

      DispatchGate.active_state?(issue.state, active) ->
        emit_decision(issue, "active_state", "refresh")
        refresh_running_issue_state(state, issue)

      true ->
        emit_decision(issue, "non_active_state", "terminate")
        Logger.info("Issue moved to non-active state: #{RunningEntry.format_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_fn.(state, issue.id, true)
    end
  end

  defp reconcile_issue_state(state, _issue, _active, _terminal, _terminate_fn, _pr_sync_fn) do
    state
  end

  defp reconcile_ready_pr(%State{} = state, %Issue{} = issue, terminate_fn, pr_sync_fn) do
    case critical_review_result(issue) do
      {:critical, info} ->
        if already_auto_reengaged?(state, issue, info) do
          emit_decision(issue, "pr_ready_with_critical_review_after_reengagement", "pr_sync+terminate")

          Logger.info(
            "Issue has a ready PR attachment with claude-pr-review request_changes after auto re-engagement: #{RunningEntry.format_context(issue)} state=#{issue.state}; stopping active agent so PrReengagement can enforce K=1 cap"
          )

          state
          |> refresh_running_issue_state(issue)
          |> pr_sync_fn.(issue.id)
          |> terminate_fn.(issue.id, true)
          |> mark_completed(issue.id)
        else
          emit_decision(issue, "pr_ready_with_critical_review", "refresh")

          Logger.info("Issue has a ready PR attachment but claude-pr-review requested changes: #{RunningEntry.format_context(issue)} state=#{issue.state}; keeping agent running")

          refresh_running_issue_state(state, issue)
        end

      _ ->
        emit_decision(issue, "pr_ready_short_circuit", "pr_sync+terminate")
        Logger.info("Issue has a ready PR attachment (MERGED or OPEN+CI-green): #{RunningEntry.format_context(issue)} state=#{issue.state}; stopping active agent without retry")

        state
        |> refresh_running_issue_state(issue)
        |> pr_sync_fn.(issue.id)
        |> terminate_fn.(issue.id, true)
        |> mark_completed(issue.id)
    end
  end

  defp critical_review_result(%Issue{} = issue) do
    GitHubPr.critical_review_pending?(issue)
  end

  defp already_auto_reengaged?(%State{} = state, %Issue{} = issue, info) when is_map(info) do
    issue
    |> review_pr_urls(info)
    |> Enum.any?(fn pr_url ->
      case Map.get(state.pr_engagements, pr_url) do
        %{count: count} when is_integer(count) and count >= 1 -> true
        _ -> false
      end
    end)
  end

  defp review_pr_urls(%Issue{} = issue, info) do
    info_pr_url =
      case Map.get(info, :pr_url) do
        url when is_binary(url) -> [url]
        _ -> []
      end

    (info_pr_url ++ pr_urls_for(issue))
    |> Enum.uniq()
  end

  defp pr_urls_for(%Issue{repos: repos}) when is_list(repos) do
    Enum.flat_map(repos, fn
      %{pr: %{url: url}} when is_binary(url) -> [url]
      _ -> []
    end)
  end

  defp pr_urls_for(_), do: []

  defp mark_completed(%State{} = state, issue_id) when is_binary(issue_id) do
    %{state | completed: MapSet.put(state.completed, issue_id)}
  end

  defp emit_decision(%Issue{} = issue, branch, action) do
    DecisionLog.emit("reconcile.decision", %{
      issue_id: issue.id,
      identifier: issue.identifier,
      linear_state: issue.state,
      branch: branch,
      action: action
    })
  end

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues, terminate_fn)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        DecisionLog.emit("reconcile.decision", %{
          issue_id: issue_id,
          identifier: get_in(state_acc.running, [issue_id, :identifier]),
          branch: "no_longer_visible",
          action: "terminate"
        })

        log_missing_running_issue(state_acc, issue_id)
        terminate_fn.(state_acc, issue_id, false)
      end
    end)
  end

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end
end
