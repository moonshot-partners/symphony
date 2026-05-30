defmodule SymphonyElixir.Orchestrator.AgentExitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.{AgentExit, State}

  defp empty_state(overrides \\ %{}) do
    Map.merge(
      %State{
        running: %{},
        claimed: MapSet.new(),
        completed: MapSet.new(),
        workpads: %{},
        retry_attempts: %{},
        agent_totals: %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: 0
        }
      },
      overrides
    )
  end

  defp running_entry(overrides \\ %{}) do
    Map.merge(
      %{
        identifier: "ISS-1",
        ref: make_ref(),
        issue: %Issue{
          id: "issue-ax-1",
          identifier: "ISS-1",
          title: "test",
          state: "In Development",
          url: "https://linear.app/issues/ISS-1"
        },
        session_id: "sess-1",
        started_at: DateTime.utc_now(),
        started_monotonic_ms: System.monotonic_time(:millisecond),
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0
      },
      overrides
    )
  end

  defp recording_completer(parent_pid) do
    fn %State{} = state, issue_id ->
      send(parent_pid, {:completer_called, issue_id})

      %{state | completed: MapSet.put(state.completed, issue_id)}
    end
  end

  defp recording_retrier(parent_pid) do
    fn {result, %State{} = state}, issue, issue_id, metadata ->
      send(parent_pid, {:retrier_called, result, issue, issue_id, metadata})
      state
    end
  end

  defp callbacks(parent_pid) do
    [
      completer: recording_completer(parent_pid),
      retrier: recording_retrier(parent_pid),
      retry_dispatch_opts: %{
        recipient: parent_pid,
        dispatch_fn: fn _state, _issue, _attempt, _host -> :ok end,
        release_claim_fn: fn state, _issue_id -> state end
      },
      recipient: parent_pid
    ]
  end

  defp set_memory_tracker_recipient do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)
  end

  describe "process_exit/4 — ref not found" do
    test "returns state unchanged when ref does not match any running entry" do
      state = empty_state(%{running: %{"issue-ax-1" => running_entry()}})
      unknown_ref = make_ref()

      assert ^state = AgentExit.process_exit(state, unknown_ref, :normal, callbacks(self()))

      refute_receive {:completer_called, _}, 100
      refute_receive {:retrier_called, _, _, _, _}, 100
    end

    test "returns state unchanged on empty running map" do
      state = empty_state()
      assert ^state = AgentExit.process_exit(state, make_ref(), :normal, callbacks(self()))
    end
  end

  describe "process_exit/4 — :normal reason" do
    test "pops entry, runs completer, schedules continuation, posts no comment" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_reject_state: "On Hold / Blocked"
      )

      set_memory_tracker_recipient()

      entry = running_entry()
      ref = entry.ref
      state = empty_state(%{running: %{"issue-ax-1" => entry}})

      new_state = AgentExit.process_exit(state, ref, :normal, callbacks(self()))

      assert_receive {:completer_called, "issue-ax-1"}, 500
      refute_receive {:retrier_called, _, _, _, _}, 200
      refute_receive {:memory_tracker_comment, _, _}, 200

      refute Map.has_key?(new_state.running, "issue-ax-1")
      assert MapSet.member?(new_state.completed, "issue-ax-1")
    end
  end

  describe "process_exit/4 — crash reason" do
    test "schedules retry via RetryAttempts and calls retrier with result tuple" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_reject_state: "On Hold / Blocked"
      )

      set_memory_tracker_recipient()

      entry = running_entry(%{worker_host: "host-a", workspace_path: "/tmp/ws"})
      state = empty_state(%{running: %{"issue-ax-1" => entry}})

      _ = AgentExit.process_exit(state, entry.ref, :killed, callbacks(self()))

      refute_receive {:completer_called, _}, 200
      assert_receive {:retrier_called, result, issue, "issue-ax-1", metadata}, 500

      assert result in [:armed, :halted]
      assert %Issue{identifier: "ISS-1"} = issue
      assert metadata.identifier == "ISS-1"
      assert metadata.worker_host == "host-a"
      assert metadata.workspace_path == "/tmp/ws"
      assert metadata.error =~ "agent exited"
      assert metadata.error =~ ":killed"
    end

    test "tolerates running_entry without worker_host or workspace_path" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_reject_state: "On Hold / Blocked"
      )

      set_memory_tracker_recipient()

      entry = running_entry()
      state = empty_state(%{running: %{"issue-ax-1" => entry}})

      _ = AgentExit.process_exit(state, entry.ref, {:shutdown, :timeout}, callbacks(self()))

      assert_receive {:retrier_called, _result, _issue, "issue-ax-1", metadata}, 500
      assert metadata.worker_host == nil
      assert metadata.workspace_path == nil
    end

    test "passes nil issue when running_entry has no :issue key" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_reject_state: "On Hold / Blocked"
      )

      set_memory_tracker_recipient()

      entry = running_entry() |> Map.delete(:issue)
      state = empty_state(%{running: %{"issue-ax-1" => entry}})

      _ = AgentExit.process_exit(state, entry.ref, :killed, callbacks(self()))

      assert_receive {:retrier_called, _result, nil, "issue-ax-1", _metadata}, 500
    end
  end
end
