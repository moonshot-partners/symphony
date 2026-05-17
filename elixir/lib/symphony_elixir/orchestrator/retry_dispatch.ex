defmodule SymphonyElixir.Orchestrator.RetryDispatch do
  @moduledoc """
  Retry / continuation dispatch decisions extracted from
  `SymphonyElixir.Orchestrator` (CP23).

  Two operations the orchestrator drives when a retry timer fires or
  an agent task completes:

    * `handle_retry_issue/5` — re-fetch the issue from the tracker and
      decide: terminal -> release claim + scrub workspace; retry
      candidate with slots -> dispatch fresh agent; retry candidate
      with no slot -> re-arm retry; no longer visible -> release
      claim.

    * `maybe_schedule_continuation_retry/4` — after an agent task exits
      cleanly, decide whether to arm a one-shot continuation retry
      (delay_type: :continuation). Capped: a PR is already attached
      and we have already burned one continuation retry — additional
      retries cannot help (the agent is stuck on infra-class CI
      failures it did not cause).

  Side effects (dispatching a fresh agent task, releasing the
  orchestrator's issue claim, fetching candidate issues from the
  tracker) are threaded through `opts` so the sibling never touches
  the surrounding GenServer state and can be exercised in tests
  against ad-hoc closures.
  """

  require Logger

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{QaEvidence, Tracker}

  alias SymphonyElixir.Orchestrator.{
    DispatchGate,
    RetryAttempts,
    RunningEntry,
    SlotPolicy,
    State,
    WorkerSelector,
    WorkspaceCleanup
  }

  @type dispatch_fn :: (State.t(), Issue.t(), term(), String.t() | nil -> State.t())
  @type release_claim_fn :: (State.t(), String.t() -> State.t())
  @type fetch_fn :: (-> {:ok, [Issue.t()]} | {:error, term()})

  @type opts :: %{
          required(:recipient) => pid(),
          required(:dispatch_fn) => dispatch_fn(),
          required(:release_claim_fn) => release_claim_fn(),
          optional(:fetch_fn) => fetch_fn()
        }

  @doc """
  Drive the retry pipeline for a single `issue_id`. Returns the
  updated `%State{}` — the orchestrator wraps it in `{:noreply,
  state}` at the call site.
  """
  @spec handle_retry_issue(State.t(), String.t(), term(), map(), opts()) :: State.t()
  def handle_retry_issue(%State{} = state, issue_id, attempt, metadata, opts)
      when is_binary(issue_id) and is_map(metadata) and is_map(opts) do
    fetch_fn = Map.get(opts, :fetch_fn, &Tracker.fetch_candidate_issues/0)

    case fetch_fn.() do
      {:ok, issues} ->
        issues
        |> RunningEntry.find_issue_by_id(issue_id)
        |> handle_lookup(state, issue_id, attempt, metadata, opts)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        RetryAttempts.schedule(
          state,
          issue_id,
          attempt + 1,
          Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"}),
          Map.fetch!(opts, :recipient)
        )
    end
  end

  @doc """
  Decide whether to arm a one-shot continuation retry after an agent
  task exits cleanly. Returns state unchanged when the loop must be
  capped (PR attached and attempt >= 1).
  """
  @spec maybe_schedule_continuation_retry(State.t(), String.t(), map(), opts()) :: State.t()
  def maybe_schedule_continuation_retry(%State{} = state, issue_id, running_entry, opts)
      when is_binary(issue_id) and is_map(running_entry) and is_map(opts) do
    has_pr = DispatchGate.has_pr_attachment?(Map.get(running_entry, :issue, %{}))
    current_attempt = Map.get(running_entry, :retry_attempt, 0)

    if has_pr and current_attempt >= 1 do
      Logger.info("Skipping continuation retry for issue_id=#{issue_id}: PR attached and attempt=#{current_attempt} >= 1; agent cannot resolve infra CI failures")
      state
    else
      RetryAttempts.schedule(
        state,
        issue_id,
        1,
        %{
          identifier: running_entry.identifier,
          delay_type: :continuation,
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path)
        },
        Map.fetch!(opts, :recipient)
      )
    end
  end

  defp handle_lookup(%Issue{} = issue, state, issue_id, attempt, metadata, opts) do
    terminal_states = DispatchGate.terminal_state_set()
    release_claim_fn = Map.fetch!(opts, :release_claim_fn)

    cond do
      DispatchGate.terminal_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        WorkspaceCleanup.cleanup_for_identifier(issue.identifier, metadata[:worker_host])
        release_claim_fn.(state, issue_id)

      DispatchGate.retry_candidate?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata, opts)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        release_claim_fn.(state, issue_id)
    end
  end

  defp handle_lookup(nil, state, issue_id, _attempt, _metadata, opts) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    Map.fetch!(opts, :release_claim_fn).(state, issue_id)
  end

  defp handle_active_retry(state, issue, attempt, metadata, opts) do
    if DispatchGate.retry_candidate?(issue, DispatchGate.terminal_state_set()) and
         SlotPolicy.dispatch_slots_available?(issue, state) and
         WorkerSelector.slots_available?(state, metadata[:worker_host]) do
      # SODEV-881: the dying workspace contains `qa-evidence/` produced by
      # the agent that just exited. The reconcile loop will fire
      # `pr_sync_fn → QaEvidence.maybe_publish` after the new agent picks
      # up, but by then the cleanup below has wiped the evidence. Snapshot
      # it to a deterministic per-issue tmp path so the publish still finds
      # it. No-op when no evidence dir exists.
      QaEvidence.stage_pending_publish(issue.id, metadata[:workspace_path])

      # SODEV-765 lesson: the previous attempt left `state/<TICKET>/qa_check.py`
      # and `qa-evidence/` in the workspace. On retry the next agent inherits
      # those files and either re-uses a stale check or trips over a dirty
      # `git status`. Wipe the workspace so retry starts from a fresh clone.
      WorkspaceCleanup.cleanup_for_identifier(issue.identifier, metadata[:worker_host])
      dispatch_fn = Map.fetch!(opts, :dispatch_fn)
      dispatch_fn.(state, issue, attempt, metadata[:worker_host])
    else
      Logger.debug("No available slots for retrying #{RunningEntry.format_context(issue)}; retrying again")

      RetryAttempts.schedule(
        state,
        issue.id,
        attempt + 1,
        Map.merge(metadata, %{
          identifier: issue.identifier,
          error: "no available orchestrator slots"
        }),
        Map.fetch!(opts, :recipient)
      )
    end
  end
end
