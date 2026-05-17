defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Agent-backed workers.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{AgentRunner, Config, Tracker, Workpad}
  alias SymphonyElixir.Linear.Issue

  alias SymphonyElixir.Orchestrator.{
    AgentTotals,
    AgentUpdate,
    Dispatch,
    DispatchGate,
    GateCTrigger,
    PreDispatch,
    PrMerge,
    ProcessLiveness,
    Reconcile,
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
    WorkerSelector,
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
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      workpads: WorkpadStore.load(workpads_path()),
      agent_totals: @empty_agent_totals,
      agent_rate_limits: nil
    }

    WorkspaceCleanup.run_terminal()
    state = TickScheduler.schedule_tick(state, 0, self())

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
    case WorkpadStore.save(workpads_path(), workpads) do
      :ok ->
        :ok

      {:error, reason} ->
        # Disk persistence failed (e.g. permission denied on
        # workpads.json). Keep the in-memory map so the GenServer survives
        # — the alternative (raise) crashes the Orchestrator, loses
        # state.running, and the supervisor restart re-dispatches every
        # ticket in Linear "In Development". Logged so the operator can
        # repair the file ownership/path.
        Logger.warning(
          "WorkpadStore.save failed (reason=#{inspect(reason)}); " <>
            "continuing with in-memory workpads only"
        )
    end

    state
  end

  defp sync_drain_status(%State{} = state, status_path, drain_flag_path) do
    drain = StatusFile.drain_requested?(drain_flag_path)

    if drain and not state.drain do
      Logger.info("Drain requested via #{drain_flag_path}; pausing dispatch of new agents")
    end

    new_state = %{state | drain: drain}
    StatusFile.save(status_path, %{running: Map.keys(new_state.running), drain: drain})
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

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case RunningEntry.find_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = RunningEntry.pop(state, issue_id)
        state = AgentTotals.record_session_completion(state, running_entry)
        RunLedgerHook.record(running_entry, issue_id)
        session_id = RunningEntry.session_id(running_entry)

        state =
          case reason do
            :normal ->
              Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

              state
              |> complete_issue(issue_id)
              |> RetryDispatch.maybe_schedule_continuation_retry(
                issue_id,
                running_entry,
                retry_dispatch_opts()
              )

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = RetryPlan.next_attempt_from_running(running_entry)

              RetryAttempts.schedule(
                state,
                issue_id,
                next_attempt,
                %{
                  identifier: running_entry.identifier,
                  error: "agent exited: #{inspect(reason)}",
                  worker_host: Map.get(running_entry, :worker_host),
                  workspace_path: Map.get(running_entry, :workspace_path)
                },
                self()
              )
          end

        Logger.info(
          "Agent task finished for issue_id=#{issue_id} session_id=#{session_id} " <>
            "reason=#{inspect(reason)} " <> RunningEntry.format_token_totals(running_entry)
        )

        notify_dashboard()
        {:noreply, state}
    end
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
        updated_running_entry = GateCTrigger.maybe_run(updated_running_entry, update)

        state =
          state
          |> AgentTotals.apply_token_delta(token_delta)
          |> AgentTotals.apply_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
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

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)
    PrMerge.reconcile()

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

        state
        |> terminate_running_issue(issue_id, false)
        |> RetryAttempts.schedule(
          issue_id,
          next_attempt,
          %{
            identifier: identifier,
            error: "worker pid dead without :DOWN message",
            worker_host: Map.get(running_entry, :worker_host),
            workspace_path: Map.get(running_entry, :workspace_path)
          },
          self()
        )
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
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    SlotPolicy.should_dispatch?(issue, state, DispatchGate.active_state_set(), DispatchGate.terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    DispatchGate.revalidate(issue, issue_fetcher, DispatchGate.terminal_state_set())
  end

  @doc false
  @spec apply_state_transition_for_test(Issue.t(), String.t() | nil) :: :ok
  def apply_state_transition_for_test(%Issue{} = issue, state_name) do
    StateTransition.apply(issue, state_name)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    WorkerSelector.select(state, preferred_worker_host)
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

    state
    |> terminate_running_issue(issue_id, false)
    |> RetryAttempts.schedule(
      issue_id,
      next_attempt,
      %{
        identifier: identifier,
        error: "stalled for #{elapsed_ms}ms without agent activity"
      },
      self()
    )
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

        RetryAttempts.schedule(
          state,
          issue.id,
          next_attempt,
          %{
            identifier: issue.identifier,
            error: "failed to spawn agent: #{inspect(reason)}",
            worker_host: worker_host
          },
          self()
        )
    end
  end

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
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
end
