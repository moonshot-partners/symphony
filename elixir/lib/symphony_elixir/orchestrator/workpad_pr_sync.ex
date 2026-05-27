defmodule SymphonyElixir.Orchestrator.WorkpadPrSync do
  @moduledoc """
  PR-attached side-effect cluster extracted from
  `SymphonyElixir.Orchestrator` (CP19). When the reconcile loop
  detects that the running issue now carries a GitHub PR attachment,
  the orchestrator forwards the running entry here for the workpad
  resync + downstream notifications (Linear state transition,
  GitHub label, QA evidence upload).

  `sync/3` returns the `%State{}` unchanged — the side-effects all
  flow through collaborator modules (`Workpad`, `StateTransition`,
  `GithubLabel`, `QaEvidence`). The orchestrator pid is threaded as
  the `recipient` argument so `Workpad.maybe_sync/3` can callback
  via `send/2` without coupling this module to `self()`.
  """

  alias SymphonyElixir.{
    Config,
    ConflictDisclosure,
    DecisionLog,
    GateDValidator,
    GitHubPr,
    GitHubPrBody,
    GitHubPrFiles,
    QaArtifactGate,
    QaEvidence,
    Tracker,
    Workpad
  }

  alias SymphonyElixir.Orchestrator.{GithubLabel, RunningEntry, State, StateTransition, TurnArtifacts}

  @doc """
  Sync the workpad comment for `issue_id` with the `pr_attached`
  event and trigger the downstream PR-attached side-effects.
  Returns the `%State{}` unchanged. No-ops (with state pass-through)
  when the issue is not in `state.running`.
  """
  @spec sync(State.t(), String.t(), pid()) :: State.t()
  def sync(%State{} = state, issue_id, recipient)
      when is_binary(issue_id) and is_pid(recipient) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      running_entry ->
        comment_id =
          Map.get(running_entry, :workpad_comment_id) || Map.get(state.workpads, issue_id)

        entry =
          running_entry
          |> Map.put(:last_agent_event, :pr_attached)
          |> RunningEntry.put_workpad_comment_id(comment_id)

        update = %{event: :pr_attached, timestamp: DateTime.utc_now()}
        _ = Workpad.maybe_sync(entry, update, recipient)

        run_side_effects(
          Map.get(running_entry, :issue),
          running_entry,
          comment_id,
          state.pr_engagements
        )

        state
    end
  end

  defp run_side_effects(nil, _running_entry, _parent_comment_id, _pr_engagements) do
    DecisionLog.emit("workpad_pr_sync.route", %{
      branch: "skip_nil_issue",
      target_state: nil
    })

    :ok
  end

  defp run_side_effects(issue, running_entry, parent_comment_id, pr_engagements) do
    reject_state = Config.settings!().tracker.on_reject_state
    complete_state = Config.settings!().tracker.on_complete_state

    if in_auto_engagement?(issue, pr_engagements) do
      # SYM-16 bypass: the agent is mid auto-re-engagement; do not park
      # in on_reject_state on this run even if QA self-reports BLOCKED
      # or CI is red — let the K=1 re-engagement land. If the next
      # claude-pr-review verdict is still critical, PrReengagement caps
      # at K=1 and parks for human review.
      emit_route("auto_engagement_bypass", issue, complete_state, pr_engagements)
      apply_completion_side_effects(issue, complete_state, running_entry, parent_comment_id)
    else
      route_by_ci_then_qa(
        issue,
        running_entry,
        parent_comment_id,
        pr_engagements,
        reject_state,
        complete_state
      )
    end
  end

  defp route_by_ci_then_qa(
         issue,
         running_entry,
         parent_comment_id,
         pr_engagements,
         reject_state,
         complete_state
       ) do
    case GitHubPr.required_checks_status(issue) do
      {:red, names} when is_binary(reject_state) ->
        # SYM-1c (SYM-29): a red required check means the agent's PR cannot
        # land as-is. Park in on_reject_state and post a workpad comment
        # naming the failing checks so a human can triage.
        emit_route("ci_red", issue, reject_state, pr_engagements, %{red_checks: names})
        post_red_checks_comment(issue, names, parent_comment_id)
        apply_completion_side_effects(issue, reject_state, running_entry, parent_comment_id)

      :pending ->
        # SYM-1c (SYM-29) AC3: checks still running — do NOT transition.
        # The orchestrator's next reconcile tick re-evaluates once GitHub
        # has decided. Skip side effects entirely so we don't double-fire
        # GithubLabel / QaEvidence before completion is real.
        emit_route("ci_pending", issue, nil, pr_engagements)
        :ok

      _ ->
        # :all_green (or :unknown verdict) — substance + conflict checks then legacy tree.
        case substance_verdict(running_entry) do
          {:fail, failures} when is_binary(reject_state) ->
            emit_route("gate_d_substance_fail", issue, reject_state, pr_engagements, %{
              unbacked_acs: Enum.map(failures, & &1.ac_id)
            })

            post_substance_fail_comment(issue, failures, parent_comment_id)
            apply_completion_side_effects(issue, reject_state, running_entry, parent_comment_id)

          _ ->
            route_post_substance(
              issue,
              running_entry,
              parent_comment_id,
              pr_engagements,
              reject_state,
              complete_state
            )
        end
    end
  end

  defp route_post_substance(
         issue,
         running_entry,
         parent_comment_id,
         pr_engagements,
         reject_state,
         complete_state
       ) do
    case conflict_verdict(issue, running_entry) do
      {:fail, undisclosed} when is_binary(reject_state) ->
        # SYM-30 (AC4 of SYM-1): the agent's PR touches files outside the
        # ticket's allowlist without disclosing them in `## Root cause`.
        # Park in on_reject_state and name the undisclosed files so a human
        # can decide whether to expand the allowlist or revert the diff.
        emit_route("conflict_disclosure_fail", issue, reject_state, pr_engagements, %{
          undisclosed_files: undisclosed
        })

        post_conflict_disclosure_comment(issue, undisclosed, parent_comment_id)
        apply_completion_side_effects(issue, reject_state, running_entry, parent_comment_id)

      _ ->
        route_post_conflict(
          issue,
          running_entry,
          parent_comment_id,
          pr_engagements,
          reject_state,
          complete_state
        )
    end
  end

  defp route_post_conflict(
         issue,
         running_entry,
         parent_comment_id,
         pr_engagements,
         reject_state,
         complete_state
       ) do
    case qa_artifact_verdict(issue, running_entry) do
      {:fail, :no_artifact} when is_binary(reject_state) ->
        # SYM-34: the agent's PR body claims `- Result: PASS` under
        # `## QA self-review` but no Playwright artifact (screenshot,
        # webm, zip) exists on disk. Park in on_reject_state — the agent
        # skipped the QA run and only wrote prose.
        emit_route("qa_artifact_missing", issue, reject_state, pr_engagements)
        post_qa_artifact_missing_comment(issue, parent_comment_id)
        apply_completion_side_effects(issue, reject_state, running_entry, parent_comment_id)

      _ ->
        route_by_qa(
          issue,
          running_entry,
          parent_comment_id,
          pr_engagements,
          reject_state,
          complete_state
        )
    end
  end

  defp route_by_qa(issue, running_entry, parent_comment_id, pr_engagements, reject_state, complete_state) do
    if GitHubPr.qa_blocked?(issue) and is_binary(reject_state) do
      emit_route("qa_blocked", issue, reject_state, pr_engagements)
      apply_completion_side_effects(issue, reject_state, running_entry, parent_comment_id)
    else
      emit_route("default_complete", issue, complete_state, pr_engagements)
      apply_completion_side_effects(issue, complete_state, running_entry, parent_comment_id)
    end
  end

  defp substance_verdict(running_entry) do
    evidence_text =
      case Map.get(running_entry, :pinned_evidence_text) do
        %{} = m -> Map.get(m, "AC Evidence")
        _ -> nil
      end

    GateDValidator.validate(evidence_text, %{workspace_path: Map.get(running_entry, :workspace_path)})
  end

  defp conflict_verdict(issue, running_entry) do
    description = Map.get(issue, :description)
    changed_files = GitHubPrFiles.changed_files(issue)
    understanding_md = read_understanding_md(Map.get(running_entry, :workspace_path))
    ConflictDisclosure.validate(description, changed_files, understanding_md)
  end

  defp qa_artifact_verdict(issue, running_entry) do
    body = GitHubPrBody.pr_body(issue)
    workspace_path = Map.get(running_entry, :workspace_path)
    issue_id = Map.get(issue, :id)
    changed_files = GitHubPrFiles.changed_files(issue)

    QaArtifactGate.validate(body, workspace_path, issue_id,
      subpaths: Config.qa_evidence_subpaths(),
      changed_files: changed_files
    )
  end

  defp read_understanding_md(workspace_path) when is_binary(workspace_path) do
    with path when is_binary(path) <- TurnArtifacts.discover_understanding_md(workspace_path),
         {:ok, content} <- File.read(path) do
      content
    else
      _ -> nil
    end
  end

  defp read_understanding_md(_), do: nil

  defp apply_completion_side_effects(issue, target_state, running_entry, parent_comment_id) do
    StateTransition.apply(issue, target_state)
    Task.start(fn -> GithubLabel.apply(issue) end)

    QaEvidence.maybe_publish(
      Map.get(issue, :id),
      Map.get(running_entry, :workspace_path),
      parent_id: parent_comment_id
    )

    :ok
  end

  defp emit_route(branch, issue, target_state, pr_engagements, extra \\ %{}) do
    base = %{
      branch: branch,
      issue_id: Map.get(issue, :id),
      identifier: Map.get(issue, :identifier),
      target_state: target_state,
      pr_engagement_keys: Map.keys(pr_engagements)
    }

    DecisionLog.emit("workpad_pr_sync.route", Map.merge(base, extra))
  end

  defp post_red_checks_comment(issue, names, parent_comment_id) do
    issue_id = Map.get(issue, :id)

    if is_binary(issue_id) do
      body = red_checks_comment_body(names)
      Task.start(fn -> Tracker.create_comment(issue_id, body, parent_id: parent_comment_id) end)
    end

    :ok
  end

  defp post_conflict_disclosure_comment(issue, undisclosed, parent_comment_id) do
    issue_id = Map.get(issue, :id)

    if is_binary(issue_id) do
      body = conflict_disclosure_comment_body(undisclosed)
      Task.start(fn -> Tracker.create_comment(issue_id, body, parent_id: parent_comment_id) end)
    end

    :ok
  end

  defp conflict_disclosure_comment_body(undisclosed) when is_list(undisclosed) do
    bullet_list = Enum.map_join(undisclosed, "\n", &"- `#{&1}`")

    """
    ## Conflict disclosure — undisclosed files in diff

    The ticket spec declared a minimal-diff allowlist via `## Files (allowed)`, but the PR touches files outside it with no mention in the agent's `## Root cause` section of `understanding.md`. Parking in `on_reject_state` so a human can decide whether to expand the allowlist or revert the diff.

    **Undisclosed files:**

    #{bullet_list}

    _Posted by SymphonyElixir.Orchestrator.WorkpadPrSync (SYM-1d/SYM-30)._
    """
  end

  defp post_qa_artifact_missing_comment(issue, parent_comment_id) do
    issue_id = Map.get(issue, :id)

    if is_binary(issue_id) do
      body = qa_artifact_missing_comment_body()
      Task.start(fn -> Tracker.create_comment(issue_id, body, parent_id: parent_comment_id) end)
    end

    :ok
  end

  defp qa_artifact_missing_comment_body do
    """
    ## QA artifact — substance verification failed

    The PR body declares `- Result: PASS` under `## QA self-review`, but no real Playwright artifact (`*.png`, `*.webm`, `*.zip`) was found in the workspace `qa-evidence/` directory or the staged retry snapshot. The agent likely wrote the QA prose without running the spec. Parking in `on_reject_state` so the retry loop or a human can re-run the QA harness end-to-end.

    _Posted by SymphonyElixir.Orchestrator.WorkpadPrSync (SYM-34)._
    """
  end

  defp post_substance_fail_comment(issue, failures, parent_comment_id) do
    issue_id = Map.get(issue, :id)

    if is_binary(issue_id) do
      body = substance_fail_comment_body(failures)
      Task.start(fn -> Tracker.create_comment(issue_id, body, parent_id: parent_comment_id) end)
    end

    :ok
  end

  defp substance_fail_comment_body(failures) when is_list(failures) do
    bullet_list =
      Enum.map_join(failures, "\n", fn %{ac_id: id, reason: reason} ->
        "- AC #{id} — #{reason}"
      end)

    """
    ## Gate D — substance verification failed

    The agent's `## AC Evidence` block contains `verified` claims that lack a resolvable artifact reference. Parking in `on_reject_state` so the retry loop or a human can investigate.

    **Unbacked claims:**

    #{bullet_list}

    _Posted by SymphonyElixir.Orchestrator.WorkpadPrSync (SYM-1b/SYM-28)._
    """
  end

  defp red_checks_comment_body(names) when is_list(names) do
    bullet_list = Enum.map_join(names, "\n", &"- `#{&1}`")

    """
    ## CI gate — required checks failing

    The agent's PR has one or more failing required checks. Parking in `on_reject_state` so the retry loop or a human can investigate.

    **Failing checks:**

    #{bullet_list}

    _Posted by SymphonyElixir.Orchestrator.WorkpadPrSync (SYM-1c)._
    """
  end

  defp in_auto_engagement?(issue, pr_engagements) when is_map(pr_engagements) do
    pr_engagements != %{} and
      issue
      |> pr_urls()
      |> Enum.any?(fn url ->
        case Map.get(pr_engagements, url) do
          %{count: count} when is_integer(count) and count >= 1 -> true
          _ -> false
        end
      end)
  end

  defp pr_urls(%{repos: repos}) when is_list(repos) do
    Enum.flat_map(repos, fn
      %{pr: %{url: url}} when is_binary(url) -> [url]
      _ -> []
    end)
  end
end
