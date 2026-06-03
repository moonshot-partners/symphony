defmodule SymphonyElixir.Orchestrator.PlanGroundingGate do
  @moduledoc """
  Soft gate for plan grounding (SYM-2). On the agent's first turn, after
  `TurnArtifacts` has discovered `understanding.md`, this checks that the
  file's `## Plan` section names real target files in the workspace — see
  `SymphonyElixir.PlanGrounding` for the pure rule.

  Symphony already asks the agent to write a citation-backed
  `understanding.md` on turn 1, but nothing on the Symphony side ever
  verified those citations. This emits that signal without interrupting the
  agent; final acceptance should come from the PR, tests, and evidence.

  `enforce/5` is the single API, fired from the orchestrator's
  `:turn_completed` handler right after `TurnArtifacts.maybe_post`:

    * grounded plan (`:ok`) → `{:continue, state, running_entry}`. The
      `:plan_grounding_checked` flag marks the entry so later turns skip
      the check.
    * ungrounded plan (`{:violation, reason}`) → records a diagnostic summary
      in the optional operational view and keeps the agent running. Returns
      `{:continue, state, running_entry}`.

  Runs once, on turn 1 only. A turn other than the first, an already
  checked entry, or a non-binary `workspace_path` is a silent pass — the
  gate never false-halts a run it cannot evaluate.

  The summary write is a fast, non-raising local-disk write done inline.
  """

  require Logger

  alias SymphonyElixir.{OperationalView, PlanGrounding}
  alias SymphonyElixir.Orchestrator.{DispatchGate, State, TurnArtifacts}

  @type opts :: keyword()

  @spec enforce(State.t(), String.t(), map(), map(), opts()) ::
          {:continue, State.t(), map()}
  def enforce(%State{} = state, issue_id, running_entry, %{event: :turn_completed}, opts)
      when is_binary(issue_id) and is_map(running_entry) and is_list(opts) do
    cond do
      Map.get(running_entry, :plan_grounding_checked) == true ->
        {:continue, state, running_entry}

      Map.get(running_entry, :turn_count) != 1 ->
        {:continue, state, running_entry}

      DispatchGate.has_pr_attachment?(Map.get(running_entry, :issue)) ->
        {:continue, state, running_entry}

      not is_binary(Map.get(running_entry, :workspace_path)) ->
        {:continue, state, running_entry}

      true ->
        check(state, issue_id, running_entry)
    end
  end

  def enforce(%State{} = state, _issue_id, running_entry, _update, _opts),
    do: {:continue, state, running_entry}

  defp check(state, issue_id, running_entry) do
    workspace_path = Map.fetch!(running_entry, :workspace_path)
    running_entry = Map.put(running_entry, :plan_grounding_checked, true)

    case PlanGrounding.validate(read_understanding_md(workspace_path), workspace_path) do
      :ok ->
        {:continue, state, running_entry}

      {:violation, reason} ->
        warn(state, issue_id, running_entry, reason)
    end
  end

  defp read_understanding_md(workspace_path) do
    with path when is_binary(path) <- TurnArtifacts.discover_understanding_md(workspace_path),
         {:ok, content} <- File.read(path) do
      content
    else
      _ -> nil
    end
  end

  defp warn(state, issue_id, running_entry, reason) do
    identifier = Map.get(running_entry, :identifier, issue_id)

    Logger.warning("Plan-grounding soft violation: issue_id=#{issue_id} issue_identifier=#{identifier} reason=#{inspect(reason)}")

    OperationalView.put_run_summary(issue_id, violation_comment(reason, identifier))

    {:continue, state, running_entry}
  end

  defp violation_comment(reason, identifier) do
    """
    ## Plan-grounding warning

    #{explain(reason)}

    Issue: #{identifier}

    The agent run was allowed to continue. This warning is diagnostic only; final acceptance should be judged by the PR, tests, and evidence.
    """
  end

  defp explain(:missing_plan_section) do
    "The agent's first turn produced no `## Plan` section in `understanding.md` (or wrote no `understanding.md` at all). Discovery is gated: the agent must read the repository and name where the change lands before writing code."
  end

  defp explain(:no_grounded_path) do
    "The `## Plan` section names no file that exists in the workspace. A plan must be anchored to at least one real file — a plan made entirely of `(new)` files, or of prose with no paths, is not grounded in the codebase."
  end

  defp explain({:path_not_found, paths}) do
    "The `## Plan` section cites files that do not exist in the workspace:\n\n" <>
      Enum.map_join(paths, "\n", &"- `#{&1}`") <>
      "\n\nThese are likely hallucinated paths. Tag a file the plan will create with `(new)`; otherwise the path must resolve to a real file."
  end
end
