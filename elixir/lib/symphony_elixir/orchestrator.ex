defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Agent-backed workers.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{AgentRunner, Config, DecisionLog, GitHubPr, Tracker, Workpad}
  alias SymphonyElixir.Cockpit.{BoardCache, EvidenceStore, RunSummaryStore}
  alias SymphonyElixir.Linear.Issue

  alias SymphonyElixir.Orchestrator.{
    AgentExit,
    AgentTotals,
    AgentUpdate,
    ArtifactPin,
    Dispatch,
    DispatchGate,
    GateCEnforcement,
    GateCTrigger,
    PlanGroundingGate,
    PreDispatch,
    ProcessLiveness,
    PrReengagement,
    Reconcile,
    Reconcilers,
    RetryAttempts,
    RetryDispatch,
    RetryPlan,
    RunLedgerHook,
    RunningEntry,
    SlotPolicy,
    Snapshot,
    StallScan,
    State,
    StateTransition,
    StatusFile,
    TickScheduler,
    TurnArtifacts,
    TurnSoftCap,
    WorkerSelector,
    WorkpadPersister,
    WorkpadPrSync,
    WorkpadStore,
    WorkspaceCleanup
  }

  @default_workpads_path "/opt/symphony/state/workpads.json"
  @default_status_path "/opt/symphony/state/status.json"
  @default_drain_flag_path "/opt/symphony/state/drain.flag"

  @empty_agent_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()
    runtime_state = StatusFile.load_runtime_state(status_path())

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      workpads: WorkpadStore.load(workpads_path()),
      agent_totals: @empty_agent_totals,
      agent_rate_limits: nil,
      completed: runtime_state.completed,
      pr_engagements: runtime_state.pr_engagements
    }

    WorkspaceCleanup.run_terminal()
    state = if Keyword.get(opts, :schedule_initial_tick, true), do: TickScheduler.schedule_tick(state, 0, self()), else: state

    {:ok, state}
  end

  defp workpads_path do
    Application.get_env(:symphony_elixir, :workpads_path, @default_workpads_path)
  end

  defp status_path do
    Application.get_env(:symphony_elixir, :status_path, @default_status_path)
  end

  defp drain_flag_path do
    Application.get_env(:symphony_elixir, :drain_flag_path, @default_drain_flag_path)
  end

  defp persist_workpads(%{workpads: workpads} = state) do
    # Hand the map to WorkpadPersister for an ordered, off-process write.
    # A synchronous File.write here would block the Orchestrator's message
    # loop on disk I/O; a failed write must never crash this process and
    # lose state.running. WorkpadPersister owns both concerns.
    WorkpadPersister.save_async(workpads_path(), workpads)
    state
  end

  defp sync_drain_status(%State{} = state, status_path, drain_flag_path) do
    drain = StatusFile.drain_requested?(drain_flag_path)

    if drain and not state.drain do
      Logger.info("Drain requested via #{drain_flag_path}; pausing dispatch of new agents")
    end

    new_state = %{state | drain: drain}

    StatusFile.save(status_path, %{
      running: Map.keys(new_state.running),
      drain: drain,
      completed: new_state.completed,
      pr_engagements: new_state.pr_engagements
    })

    new_state
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = TickScheduler.refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = TickScheduler.schedule_poll_cycle_start(self())
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = TickScheduler.refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = TickScheduler.schedule_poll_cycle_start(self())
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    emit_tick(state)

    state =
      try do
        state = TickScheduler.refresh_runtime_config(state)
        state = sync_drain_status(state, status_path(), drain_flag_path())
        maybe_dispatch(state)
      rescue
        e ->
          Logger.error("Poll cycle exception: #{inspect(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}")

          state
      end

    state = TickScheduler.schedule_tick(state, state.poll_interval_ms, self())
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{} = state) do
    state = AgentExit.process_exit(state, ref, reason, agent_exit_opts())
    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> RunningEntry.put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> RunningEntry.put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:agent_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = AgentUpdate.integrate(running_entry, update)
        updated_running_entry = Workpad.maybe_sync(updated_running_entry, update, self())
        {gate_c_result, updated_running_entry} = GateCTrigger.maybe_run(updated_running_entry, update)

        enforce_opts = [terminate_fn: &terminate_running_issue/3]

        case GateCEnforcement.enforce(gate_c_result, state, issue_id, updated_running_entry, enforce_opts) do
          {:halted, state} ->
            state =
              state
              |> AgentTotals.apply_token_delta(token_delta)
              |> AgentTotals.apply_rate_limits(update)

            notify_dashboard()
            {:noreply, state}

          {:continue, state} ->
            apply_plan_grounding(state, issue_id, updated_running_entry, update, token_delta, enforce_opts)
        end
    end
  end

  def handle_info({:agent_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:workpad_comment_created, issue_id, comment_id}, %{running: running} = state)
      when is_binary(issue_id) and is_binary(comment_id) do
    state =
      %{state | workpads: Map.put(state.workpads, issue_id, comment_id)}
      |> persist_workpads()

    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        running_entry =
          running_entry
          |> Map.put(:workpad_comment_id, comment_id)
          |> Map.delete(:workpad_creating)

        {:noreply, %{state | running: Map.put(running, issue_id, running_entry)}}
    end
  end

  def handle_info({:workpad_create_failed, issue_id, _reason}, %{running: running} = state)
      when is_binary(issue_id) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        running_entry = Map.delete(running_entry, :workpad_creating)
        {:noreply, %{state | running: Map.put(running, issue_id, running_entry)}}
    end
  end

  def handle_info({:workpad_update_failed, issue_id, _comment_id, _reason}, state)
      when is_binary(issue_id) do
    # The comment no longer exists in Linear (e.g. deleted after a ticket reset).
    # Clear the stale id so the next sync dispatches a CREATE instead of
    # repeatedly failing to UPDATE a ghost comment.
    state = %{state | workpads: Map.delete(state.workpads, issue_id)} |> persist_workpads()

    case Map.get(state.running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        running_entry =
          running_entry
          |> Map.delete(:workpad_comment_id)
          |> Map.delete(:workpad_creating)

        {:noreply, %{state | running: Map.put(state.running, issue_id, running_entry)}}
    end
  end

  def handle_info({:workpad_update_failed, _issue_id, _comment_id, _reason}, state) do
    {:noreply, state}
  end

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    new_state =
      case RetryAttempts.pop(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} ->
          RetryDispatch.handle_retry_issue(state, issue_id, attempt, metadata, retry_dispatch_opts())

        :missing ->
          state
      end

    notify_dashboard()
    {:noreply, new_state}
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Gate C passed: post the turn-1 understanding.md artifact, then run the
  # plan-grounding gate. A grounded plan pins the AC artifacts and keeps the
  # run alive; an ungrounded plan halts it.
  defp apply_plan_grounding(state, issue_id, running_entry, update, token_delta, enforce_opts) do
    TurnArtifacts.maybe_post(running_entry, update, issue_id)
    running_entry = TurnSoftCap.maybe_emit(running_entry, update, issue_id)

    case PlanGroundingGate.enforce(state, issue_id, running_entry, update, enforce_opts) do
      {:halted, state} ->
        state =
          state
          |> AgentTotals.apply_token_delta(token_delta)
          |> AgentTotals.apply_rate_limits(update)

        notify_dashboard()
        {:noreply, state}

      {:continue, state, running_entry} ->
        running_entry =
          running_entry
          |> ArtifactPin.pin(issue_id, "AC Extracted")
          |> ArtifactPin.pin(issue_id, "AC Evidence")

        state =
          state
          |> AgentTotals.apply_token_delta(token_delta)
          |> AgentTotals.apply_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(state.running, issue_id, running_entry)}}
    end
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)
    Reconcilers.tick()

    if state.drain do
      state
    else
      do_dispatch(state)
    end
  end

  defp do_dispatch(%State{} = state) do
    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues(),
         true <- SlotPolicy.available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_or_team_key} ->
        Logger.error("Linear filter missing in WORKFLOW.md: set project_slug, team_key, or both")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state
    |> reconcile_dead_workers()
    |> reconcile_stalled_running_issues()
    |> Reconcile.run(%{
      terminate_fn: &terminate_running_issue/3,
      pr_sync_fn: fn s, id -> WorkpadPrSync.sync(s, id, self()) end
    })
    |> reconcile_pr_reengagement()
  end

  # Caller-side short-circuit to avoid building the opts map on every
  # poll tick when `state.completed` is empty. The opts map costs a
  # `Config.settings!()` GenServer round-trip (~700ms via WorkflowStore
  # YAML parse), which is enough to push the :run_poll_cycle latency
  # past the 10ms retry-arming budget in `core_test.exs:721`.
  # `PrReengagement.run/2` defends against the same empty-completed
  # case itself, so it is safe to call unconditionally from other
  # callers; this guard is purely an optimization for the poll hot
  # path.
  defp reconcile_pr_reengagement(%State{completed: completed} = state) do
    if MapSet.size(completed) == 0, do: state, else: do_pr_reengagement(state)
  end

  defp do_pr_reengagement(state) do
    settings = Config.settings!()

    PrReengagement.run(state, %{
      issue_fetch_fn: &Tracker.fetch_issue_states_by_ids/1,
      detector_fn: &GitHubPr.critical_review_pending?/1,
      pr_resolved_fn: &GitHubPr.pr_merged_or_closed?/1,
      state_transition_fn: &StateTransition.apply/2,
      comment_fn: fn issue_id, body, parent_id ->
        Tracker.create_comment(issue_id, body, parent_id: parent_id)
      end,
      pickup_state: settings.tracker.on_pickup_state,
      reject_state: settings.tracker.on_reject_state
    })
  end

  defp reconcile_dead_workers(%State{} = state) do
    if map_size(state.running) == 0 do
      state
    else
      state.running
      |> ProcessLiveness.dead_issue_ids()
      |> Enum.reduce(state, &restart_dead_worker/2)
    end
  end

  defp restart_dead_worker(issue_id, %State{} = state) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      running_entry ->
        identifier = Map.get(running_entry, :identifier, issue_id)
        session_id = RunningEntry.session_id(running_entry)

        Logger.warning(
          "Dead worker detected: issue_id=#{issue_id} issue_identifier=#{identifier} " <>
            "session_id=#{session_id}; :DOWN was not delivered, treating as failed exit"
        )

        next_attempt = RetryPlan.next_attempt_from_running(running_entry)

        dead_metadata = %{
          identifier: identifier,
          error: "worker pid dead without :DOWN message",
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path)
        }

        state
        |> terminate_running_issue(issue_id, false)
        |> RetryAttempts.schedule(issue_id, next_attempt, dead_metadata, self())
        |> handle_retry_schedule(Map.get(running_entry, :issue), issue_id, dead_metadata)
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    Reconcile.reconcile_issue_states(state, issues, &terminate_running_issue/3, fn s, id ->
      WorkpadPrSync.sync(s, id, self())
    end)
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    Reconcile.reconcile_issue_states(state, issues, &terminate_running_issue/3, fn s, id ->
      WorkpadPrSync.sync(s, id, self())
    end)
  end

  @doc false
  @spec sync_drain_status_for_test(term(), Path.t(), Path.t()) :: term()
  def sync_drain_status_for_test(%State{} = state, status_path, drain_flag_path) do
    sync_drain_status(state, status_path, drain_flag_path)
  end

  @doc false
  @spec maybe_dispatch_for_test(term()) :: term()
  def maybe_dispatch_for_test(%State{} = state), do: maybe_dispatch(state)

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    DecisionLog.emit("orchestrator.terminate", %{issue_id: issue_id, cleanup_workspace: cleanup_workspace, had_running_entry: Map.has_key?(state.running, issue_id)})

    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = AgentTotals.record_session_completion(state, running_entry)
        RunLedgerHook.record(running_entry, issue_id)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          WorkspaceCleanup.cleanup_for_identifier(identifier, worker_host)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        workpads =
          if cleanup_workspace do
            Map.delete(state.workpads, issue_id)
          else
            state.workpads
          end

        new_state = %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id),
            workpads: workpads
        }

        if cleanup_workspace, do: persist_workpads(new_state), else: new_state

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().agent_runtime.stall_timeout_ms

    if timeout_ms <= 0 or map_size(state.running) == 0 do
      state
    else
      state.running
      |> StallScan.find_stalled(DateTime.utc_now(), timeout_ms)
      |> Enum.reduce(state, &restart_stalled_issue/2)
    end
  end

  defp restart_stalled_issue(stalled, state) do
    %{
      issue_id: issue_id,
      identifier: identifier,
      session_id: session_id,
      running_entry: running_entry,
      elapsed_ms: elapsed_ms
    } = stalled

    Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

    next_attempt = RetryPlan.next_attempt_from_running(running_entry)
    stall_metadata = %{identifier: identifier, error: "stalled for #{elapsed_ms}ms without agent activity"}

    state
    |> terminate_running_issue(issue_id, false)
    |> RetryAttempts.schedule(issue_id, next_attempt, stall_metadata, self())
    |> handle_retry_schedule(Map.get(running_entry, :issue), issue_id, stall_metadata)
  end

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    active_states = DispatchGate.active_state_set()
    terminal_states = DispatchGate.terminal_state_set()

    issues
    |> Dispatch.sort()
    |> Enum.reduce(state, fn issue, state_acc ->
      if SlotPolicy.should_dispatch?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case DispatchGate.revalidate(issue, &Tracker.fetch_issue_states_by_ids/1, DispatchGate.terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        case PreDispatch.check(refreshed_issue) do
          :ok ->
            do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)

          {:reject, code, msg} ->
            PreDispatch.apply_reject(refreshed_issue, code, msg)
            %{state | completed: MapSet.put(state.completed, refreshed_issue.id)}
        end

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{RunningEntry.format_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info(
          "Skipping stale dispatch after issue refresh: #{RunningEntry.format_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}"
        )

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{RunningEntry.format_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    recipient = self()

    case WorkerSelector.select(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{RunningEntry.format_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
    pickup_state = Config.settings!().tracker.on_pickup_state

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient, attempt: attempt, worker_host: worker_host)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{RunningEntry.format_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            last_agent_message: nil,
            last_agent_timestamp: nil,
            last_agent_event: nil,
            agent_pid: nil,
            agent_input_tokens: 0,
            agent_output_tokens: 0,
            agent_total_tokens: 0,
            agent_last_reported_input_tokens: 0,
            agent_last_reported_output_tokens: 0,
            agent_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: RetryPlan.normalize_attempt(attempt),
            started_at: DateTime.utc_now(),
            workpad_comment_id: Map.get(state.workpads, issue.id)
          })

        StateTransition.apply(issue, pickup_state)

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{RunningEntry.format_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil
        spawn_metadata = %{identifier: issue.identifier, error: "failed to spawn agent: #{inspect(reason)}", worker_host: worker_host}

        RetryAttempts.schedule(state, issue.id, next_attempt, spawn_metadata, self())
        |> handle_retry_schedule(issue, issue.id, spawn_metadata)
    end
  end

  defp handle_retry_schedule({:armed, state}, _issue, _issue_id, _metadata), do: state

  defp handle_retry_schedule({:halted, state}, issue, issue_id, metadata) do
    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      error = metadata[:error] || "unknown"
      max = Config.settings!().agent.max_retries

      body = """
      ## Retry cap reached

      This issue failed #{max} consecutive times and will not be retried automatically.

      Last error: #{error}

      Investigate the root cause, then move the issue back to the dispatch queue.
      """

      Tracker.create_comment(issue_id, body)
      StateTransition.apply(issue, Config.settings!().tracker.on_reject_state)
    end)

    complete_issue(state, issue_id)
  end

  defp complete_issue(%State{} = state, issue_id) do
    DecisionLog.emit("orchestrator.complete", %{issue_id: issue_id, pr_engagement_keys: Map.keys(state.pr_engagements)})

    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  # Silence idle ticks (no running + no completed + no claims). With the
  # default 30s poll interval that gate is the difference between zero
  # JSONL lines and ~2,880/day forever. Diagnostic value only exists when
  # there is state worth observing — every claim-or-complete bumps the
  # gate so the PR re-engagement bake window stays fully covered.
  defp emit_tick(%State{} = state) do
    if map_size(state.running) > 0 or MapSet.size(state.completed) > 0 or MapSet.size(state.claimed) > 0 do
      DecisionLog.emit("orchestrator.tick", %{
        running_keys: Map.keys(state.running),
        completed_size: MapSet.size(state.completed),
        pr_engagement_keys: Map.keys(state.pr_engagements),
        drain: state.drain
      })
    end
  end

  defp notify_dashboard, do: :ok

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp retry_dispatch_opts do
    %{
      recipient: self(),
      dispatch_fn: &dispatch_issue/4,
      release_claim_fn: &release_issue_claim/2
    }
  end

  defp agent_exit_opts do
    [
      completer: &complete_issue/2,
      retrier: &handle_retry_schedule/4,
      retry_dispatch_opts: retry_dispatch_opts(),
      recipient: self()
    ]
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec stop_run(String.t()) :: {:ok, map()} | {:error, :not_running | :unavailable}
  def stop_run(issue_id) when is_binary(issue_id), do: stop_run(__MODULE__, issue_id)

  @spec stop_run(GenServer.server(), String.t()) :: {:ok, map()} | {:error, :not_running | :unavailable}
  def stop_run(server, issue_id) when is_binary(issue_id) do
    if Process.whereis(server) do
      GenServer.call(server, {:stop_run, issue_id}, 15_000)
    else
      {:error, :unavailable}
    end
  end

  @spec run_issue(String.t()) :: {:ok, map()} | {:error, atom()}
  def run_issue(identifier) when is_binary(identifier), do: run_issue(__MODULE__, identifier)

  @spec run_issue(GenServer.server(), String.t()) :: {:ok, map()} | {:error, atom()}
  def run_issue(server, identifier) when is_binary(identifier) do
    if Process.whereis(server) do
      GenServer.call(server, {:manual_dispatch, identifier, :run}, 15_000)
    else
      {:error, :unavailable}
    end
  end

  @spec rerun_issue(String.t()) :: {:ok, map()} | {:error, atom()}
  def rerun_issue(identifier) when is_binary(identifier), do: rerun_issue(__MODULE__, identifier)

  @spec rerun_issue(GenServer.server(), String.t()) :: {:ok, map()} | {:error, atom()}
  def rerun_issue(server, identifier) when is_binary(identifier) do
    if Process.whereis(server) do
      GenServer.call(server, {:manual_dispatch, identifier, :rerun}, 15_000)
    else
      {:error, :unavailable}
    end
  end

  @spec reset_issue(String.t()) :: {:ok, map()} | {:error, atom()}
  def reset_issue(identifier) when is_binary(identifier), do: reset_issue(__MODULE__, identifier)

  @spec reset_issue(GenServer.server(), String.t()) :: {:ok, map()} | {:error, atom()}
  def reset_issue(server, identifier) when is_binary(identifier) do
    if Process.whereis(server) do
      GenServer.call(server, {:reset_issue, identifier}, 15_000)
    else
      {:error, :unavailable}
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = TickScheduler.refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)
    {:reply, Snapshot.build(state, now, now_ms), state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: TickScheduler.schedule_tick(state, 0, self())

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  def handle_call({:stop_run, issue_id}, _from, %State{} = state) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      nil ->
        {:reply, {:error, :not_running}, state}

      running_entry ->
        identifier = Map.get(running_entry, :identifier, issue_id)
        session_id = RunningEntry.session_id(running_entry)

        state =
          state
          |> terminate_running_issue(issue_id, false)
          |> sync_drain_status(status_path(), drain_flag_path())

        BoardCache.invalidate()
        notify_dashboard()

        {:reply,
         {:ok,
          %{
            stopped: true,
            issue_id: issue_id,
            identifier: identifier,
            session_id: session_id,
            cleanup_workspace: false
          }}, state}
    end
  end

  def handle_call({:manual_dispatch, identifier, mode}, _from, %State{} = state)
      when is_binary(identifier) and mode in [:run, :rerun] do
    case manual_issue(identifier, state) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, %Issue{} = issue} ->
        cond do
          state.drain ->
            {:reply, {:error, :draining}, state}

          mode == :rerun ->
            rerun_issue_from_scratch(state, issue)

          running_identifier?(state, issue.identifier) ->
            {:reply, {:error, :already_running}, state}

          true ->
            state = dispatch_issue(state, issue)
            BoardCache.invalidate()
            notify_dashboard()

            if Map.has_key?(state.running, issue.id) do
              {:reply,
               {:ok,
                %{
                  queued: true,
                  mode: Atom.to_string(mode),
                  issue_id: issue.id,
                  identifier: issue.identifier
                }}, state}
            else
              {:reply, {:error, :not_dispatchable}, state}
            end
        end
    end
  end

  def handle_call({:reset_issue, identifier}, _from, %State{} = state) when is_binary(identifier) do
    case manual_issue(identifier, state) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, %Issue{} = issue} ->
        was_running = Map.has_key?(state.running, issue.id)

        state =
          state
          |> terminate_running_issue(issue.id, false)
          |> Map.update!(:workpads, &Map.delete(&1, issue.id))
          |> Map.update!(:completed, &MapSet.delete(&1, issue.id))
          |> Map.update!(:retry_attempts, &Map.delete(&1, issue.id))
          |> persist_workpads()
          |> sync_drain_status(status_path(), drain_flag_path())

        BoardCache.invalidate()
        notify_dashboard()

        {:reply,
         {:ok,
          %{
            reset: true,
            issue_id: issue.id,
            identifier: issue.identifier,
            stopped_running: was_running,
            cleared: ["workpad_pointer", "completed_marker", "retry_attempt"],
            preserved: ["workspace", "pull_request", "linear_comments", "evidence"]
          }}, state}
    end
  end

  defp rerun_issue_from_scratch(%State{} = state, %Issue{} = issue) do
    dispatch_state = manual_dispatch_state()

    case Tracker.update_issue_state(issue.id, dispatch_state) do
      :ok ->
        was_running = Map.has_key?(state.running, issue.id)

        {state, cleanup} =
          state
          |> terminate_running_issue(issue.id, true)
          |> destructive_rerun_cleanup(issue)

        state =
          state
          |> Map.update!(:workpads, &Map.delete(&1, issue.id))
          |> Map.update!(:completed, &MapSet.delete(&1, issue.id))
          |> Map.update!(:claimed, &MapSet.delete(&1, issue.id))
          |> Map.update!(:retry_attempts, &Map.delete(&1, issue.id))
          |> Map.update!(:pr_engagements, &Map.delete(&1, issue.id))
          |> persist_workpads()
          |> TickScheduler.schedule_tick(0, self())

        BoardCache.invalidate()
        notify_dashboard()

        {:reply,
         {:ok,
          %{
            queued: true,
            mode: "rerun",
            issue_id: issue.id,
            identifier: issue.identifier,
            moved_to: dispatch_state,
            stopped_running: was_running,
            destroyed: [
              "workspace",
              "pull_request",
              "linear_comments",
              "workpad_pointer",
              "completion_summary",
              "evidence",
              "completed_marker",
              "claimed_marker",
              "retry_attempt",
              "pr_engagement_marker"
            ],
            preserved: ["linear_issue", "run_ledger"],
            cleanup: cleanup
          }}, state}

      {:error, reason} ->
        Logger.warning("Manual rerun state transition failed identifier=#{issue.identifier}: #{inspect(reason)}")
        {:reply, {:error, :state_transition_failed}, state}
    end
  end

  defp destructive_rerun_cleanup(%State{} = state, %Issue{} = issue) do
    WorkspaceCleanup.cleanup_for_identifier(issue.identifier)
    EvidenceStore.delete(issue.id)
    RunSummaryStore.delete(issue.id)

    comment_cleanup =
      case Tracker.delete_issue_comments(issue.id) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end

    pr_cleanup = GitHubPr.close_for_issue(issue)

    {state, %{linear_comments: comment_cleanup, pull_requests: pr_cleanup}}
  end

  defp running_identifier?(%State{running: running}, identifier) when is_binary(identifier) do
    Enum.any?(running, fn
      {_issue_id, %{identifier: ^identifier}} -> true
      _ -> false
    end)
  end

  defp running_identifier?(_state, _identifier), do: false

  defp manual_issue(identifier, %State{} = state) do
    normalized = String.upcase(String.trim(identifier))

    state.running
    |> Map.values()
    |> Enum.find_value(fn
      %{identifier: ^normalized, issue: %Issue{} = issue} -> {:ok, issue}
      _ -> nil
    end)
    |> case do
      {:ok, %Issue{} = issue} -> {:ok, issue}
      nil -> fetch_manual_issue(normalized)
    end
  end

  defp fetch_manual_issue(identifier) do
    case Tracker.fetch_recent_issues_by_states(manual_issue_states()) do
      {:ok, issues} ->
        case Enum.find(issues, &(String.upcase(to_string(&1.identifier)) == identifier)) do
          %Issue{} = issue -> {:ok, issue}
          nil -> {:error, :not_found}
        end

      {:error, reason} ->
        Logger.warning("Manual issue lookup failed identifier=#{identifier}: #{inspect(reason)}")
        {:error, :lookup_failed}
    end
  end

  defp manual_issue_states do
    settings = Config.settings!()
    tracker = settings.tracker
    cockpit = settings.cockpit

    [
      tracker.active_states,
      tracker.terminal_states,
      [
        tracker.on_pickup_state,
        tracker.on_complete_state,
        tracker.on_pr_merge_state,
        tracker.on_reject_state,
        tracker.on_exhaust_state,
        tracker.on_promote_state
      ],
      cockpit.up_next_states,
      cockpit.done_states,
      cockpit.in_progress_states
    ]
    |> List.flatten()
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp manual_dispatch_state do
    Config.settings!().tracker.active_states
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
    |> case do
      state when is_binary(state) -> state
      _ -> Config.settings!().tracker.on_pickup_state || "In Development"
    end
  end
end
