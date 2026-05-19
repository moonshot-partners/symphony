defmodule SymphonyElixir.Orchestrator.GateCEnforcementTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.{GateCEnforcement, State}

  defp empty_state(overrides) do
    Map.merge(
      %State{
        running: %{},
        claimed: MapSet.new(),
        completed: MapSet.new(),
        workpads: %{},
        retry_attempts: %{}
      },
      overrides
    )
  end

  defp running_entry(overrides \\ %{}) do
    Map.merge(
      %{
        identifier: "ISS-1",
        issue: %Issue{
          id: "issue-gce-1",
          identifier: "ISS-1",
          title: "test",
          state: "In Development",
          url: "https://linear.app/issues/ISS-1"
        }
      },
      overrides
    )
  end

  defp recording_terminate_fn(parent_pid) do
    fn %State{} = state, issue_id, cleanup ->
      send(parent_pid, {:terminate_called, issue_id, cleanup})

      %{
        state
        | running: Map.delete(state.running, issue_id),
          claimed: MapSet.delete(state.claimed, issue_id),
          retry_attempts: Map.delete(state.retry_attempts, issue_id)
      }
    end
  end

  defp set_memory_tracker_recipient do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)
  end

  describe "enforce/5 — :ok passthrough" do
    test "returns {:continue, state} unchanged and emits no side effects" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_reject_state: "On Hold / Blocked"
      )

      set_memory_tracker_recipient()

      entry = running_entry()
      state = empty_state(%{running: %{"issue-gce-1" => entry}})

      assert {:continue, ^state} =
               GateCEnforcement.enforce(:ok, state, "issue-gce-1", entry, terminate_fn: recording_terminate_fn(self()))

      refute_receive {:terminate_called, _, _}, 100
      refute_receive {:memory_tracker_comment, _, _}, 100
      refute_receive {:memory_tracker_state_update, _, _}, 100
    end
  end

  describe "enforce/5 — {:violation, reason} hard halt" do
    test "posts parked comment, terminates running, moves state, marks completed" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_reject_state: "On Hold / Blocked"
      )

      set_memory_tracker_recipient()

      entry = running_entry()

      state =
        empty_state(%{
          running: %{"issue-gce-1" => entry},
          claimed: MapSet.new(["issue-gce-1"])
        })

      assert {:halted, halted_state} =
               GateCEnforcement.enforce({:violation, :missing_header}, state, "issue-gce-1", entry, terminate_fn: recording_terminate_fn(self()))

      assert_receive {:terminate_called, "issue-gce-1", false}, 500

      assert_receive {:memory_tracker_comment, "issue-gce-1", body}, 500
      assert body =~ "Gate C violation"
      assert body =~ "issue parked"
      assert body =~ "missing_header"
      assert body =~ "ISS-1"

      assert_receive {:memory_tracker_state_update, "issue-gce-1", "On Hold / Blocked"}, 500

      assert MapSet.member?(halted_state.completed, "issue-gce-1")
      refute Map.has_key?(halted_state.running, "issue-gce-1")
      refute MapSet.member?(halted_state.claimed, "issue-gce-1")
    end

    test ":empty_message reason renders in comment" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_reject_state: "On Hold / Blocked"
      )

      set_memory_tracker_recipient()

      entry = running_entry()
      state = empty_state(%{running: %{"issue-gce-1" => entry}})

      assert {:halted, _} =
               GateCEnforcement.enforce({:violation, :empty_message}, state, "issue-gce-1", entry, terminate_fn: recording_terminate_fn(self()))

      assert_receive {:memory_tracker_comment, "issue-gce-1", body}, 500
      assert body =~ "empty_message"
    end

    test "skips state move when running_entry.issue is nil but still posts comment + terminates" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_reject_state: "On Hold / Blocked"
      )

      set_memory_tracker_recipient()

      entry = running_entry(%{issue: nil})
      state = empty_state(%{running: %{"issue-gce-1" => entry}})

      assert {:halted, halted_state} =
               GateCEnforcement.enforce({:violation, :missing_header}, state, "issue-gce-1", entry, terminate_fn: recording_terminate_fn(self()))

      assert_receive {:terminate_called, "issue-gce-1", false}, 500
      assert_receive {:memory_tracker_comment, "issue-gce-1", _}, 500
      refute_receive {:memory_tracker_state_update, _, _}, 200

      assert MapSet.member?(halted_state.completed, "issue-gce-1")
    end

    test "tolerates running_entry without :identifier — falls back to issue_id in comment" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_reject_state: "On Hold / Blocked"
      )

      set_memory_tracker_recipient()

      entry = running_entry() |> Map.delete(:identifier)
      state = empty_state(%{running: %{"issue-gce-1" => entry}})

      assert {:halted, _} =
               GateCEnforcement.enforce({:violation, :missing_header}, state, "issue-gce-1", entry, terminate_fn: recording_terminate_fn(self()))

      assert_receive {:memory_tracker_comment, "issue-gce-1", body}, 500
      assert body =~ "issue-gce-1"
    end
  end
end
