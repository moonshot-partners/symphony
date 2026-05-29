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
    Workpad
  }

  alias SymphonyElixir.Orchestrator.{
    CompletionSummary,
    GithubLabel,
    RunningEntry,
    State,
    StateTransition,
    TurnArtifacts
  }

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
      # or CI is red — let the bounded re-engagement land. Later blocking
      # claude-pr-review verdicts are handled by PrReengagement.
      emit_route("auto_engagement_bypass", issue, complete_state, pr_engagements)
      apply_completion_side_effects(issue, complete_state, running_entry, parent_comment_id, :ready_for_review)
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
        # land as-is. Park in on_reject_state and publish one final
        # summary naming the failing checks so a human can triage.
        emit_route("ci_red", issue, reject_state, pr_engagements, %{red_checks: names})
        apply_completion_side_effects(issue, reject_state, running_entry, parent_comment_id, {:ci_red, names})

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

            apply_completion_side_effects(
              issue,
              reject_state,
              running_entry,
              parent_comment_id,
              {:gate_d_substance_fail, failures}
            )

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

        apply_completion_side_effects(
          issue,
          reject_state,
          running_entry,
          parent_comment_id,
          {:conflict_disclosure_fail, undisclosed}
        )

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
        # SYM-34: the agent's PR body or ticket contract requires visual
        # QA evidence, but no Playwright artifact (screenshot, webm, zip)
        # exists on disk. Park in on_reject_state — the agent skipped the
        # QA run and only wrote prose.
        emit_route("qa_artifact_missing", issue, reject_state, pr_engagements)
        apply_completion_side_effects(issue, reject_state, running_entry, parent_comment_id, :qa_artifact_missing)

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
      apply_completion_side_effects(issue, reject_state, running_entry, parent_comment_id, :qa_blocked)
    else
      emit_route("default_complete", issue, complete_state, pr_engagements)
      apply_completion_side_effects(issue, complete_state, running_entry, parent_comment_id, :ready_for_review)
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
      changed_files: changed_files,
      issue_description: Map.get(issue, :description)
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

  defp apply_completion_side_effects(issue, target_state, running_entry, parent_comment_id, reason) do
    StateTransition.apply(issue, target_state)
    Task.start(fn -> GithubLabel.apply(issue) end)
    CompletionSummary.publish_async(issue, target_state, running_entry, reason, parent_comment_id)

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
