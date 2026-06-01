defmodule SymphonyElixir.Orchestrator.PlanGroundingGate do
  @moduledoc """
  Hard gate for plan grounding (SYM-2). On the agent's first turn, after
  `TurnArtifacts` has discovered `understanding.md`, this checks that the
  file's `## Plan` section names real target files in the workspace — see
  `SymphonyElixir.PlanGrounding` for the pure rule.

  Symphony already asks the agent to write a citation-backed
  `understanding.md` on turn 1, but nothing on the Symphony side ever
  verified those citations. An agent could name a plausible-but-wrong file
  and proceed — shipping correct code in the wrong place. This gate closes
  that gap with a machine check, the same way `GateCEnforcement`
  machine-checks the `## AC Extracted` header.

  `enforce/5` is the single API, fired from the orchestrator's
  `:turn_completed` handler right after `TurnArtifacts.maybe_post`:

    * grounded plan (`:ok`) → `{:continue, state, running_entry}`. The
      `:plan_grounding_checked` flag marks the entry so later turns skip
      the check.
    * ungrounded plan (`{:violation, reason}`) → records a parked-issue
      summary in the cockpit run summary store, moves the issue to
      `tracker.on_reject_state`, calls the orchestrator-supplied
      `terminate_fn` to kill the running task, and marks the issue completed
      so reconcile does not redispatch it. Returns `{:halted, state}`.

  Runs once, on turn 1 only. A turn other than the first, an already
  checked entry, or a non-binary `workspace_path` is a silent pass — the
  gate never false-halts a run it cannot evaluate.

  The summary write is a fast, non-raising local-disk write done inline; the
  state move (tracker I/O) runs inside a `Task.Supervisor.start_child` so the
  orchestrator process is never blocked on the network.
  """

  require Logger

  alias SymphonyElixir.Cockpit.RunSummaryStore
  alias SymphonyElixir.{Config, PlanGrounding}
  alias SymphonyElixir.Orchestrator.{DispatchGate, State, StateTransition, TurnArtifacts}

  @type opts :: [terminate_fn: (State.t(), String.t(), boolean() -> State.t())]

  @spec enforce(State.t(), String.t(), map(), map(), opts()) ::
          {:continue, State.t(), map()} | {:halted, State.t()}
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
        check(state, issue_id, running_entry, opts)
    end
  end

  def enforce(%State{} = state, _issue_id, running_entry, _update, _opts),
    do: {:continue, state, running_entry}

  defp check(state, issue_id, running_entry, opts) do
    workspace_path = Map.fetch!(running_entry, :workspace_path)
    running_entry = Map.put(running_entry, :plan_grounding_checked, true)

    case PlanGrounding.validate(read_understanding_md(workspace_path), workspace_path) do
      :ok ->
        {:continue, state, running_entry}

      {:violation, reason} ->
        halt(state, issue_id, running_entry, reason, opts)
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

  defp halt(state, issue_id, running_entry, reason, opts) do
    terminate_fn = Keyword.fetch!(opts, :terminate_fn)
    identifier = Map.get(running_entry, :identifier, issue_id)
    issue = Map.get(running_entry, :issue)
    on_reject_state = Config.settings!().tracker.on_reject_state

    Logger.warning("Plan-grounding hard halt: issue_id=#{issue_id} issue_identifier=#{identifier} reason=#{inspect(reason)}")

    RunSummaryStore.put(issue_id, violation_comment(reason, identifier))

    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      StateTransition.apply(issue, on_reject_state)
    end)

    state = terminate_fn.(state, issue_id, false)
    {:halted, %{state | completed: MapSet.put(state.completed, issue_id)}}
  end

  defp violation_comment(reason, identifier) do
    """
    ## Plan-grounding violation — issue parked

    #{explain(reason)}

    Issue: #{identifier}

    The agent run has been terminated and the issue moved to a parked state for human review. The turn-1 `understanding.md` must carry a `## Plan` section that names every target file as a backtick-quoted, workspace-relative path; a file the plan will create is tagged `(new)` on its line. To re-dispatch, move the issue back to the dispatch queue.
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
