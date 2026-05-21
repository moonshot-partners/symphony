defmodule SymphonyElixir.Orchestrator.PlanGroundingGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.{PlanGroundingGate, State}

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

  defp running_entry(overrides) do
    Map.merge(
      %{
        identifier: "ISS-1",
        turn_count: 1,
        issue: %Issue{
          id: "issue-pg-1",
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

  # Gate opts carrying a terminate_fn that records its call into the test
  # process mailbox — self() resolves to the test pid at call time.
  defp gate_opts, do: [terminate_fn: recording_terminate_fn(self())]

  defp turn_completed, do: %{event: :turn_completed}

  defp memory_workflow do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_on_reject_state: "On Hold / Blocked"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)
  end

  # Builds a workspace dir with a real target file and an understanding.md
  # carrying `plan_body` (raw markdown). A nil `plan_body` writes no file.
  defp workspace_with(plan_body) do
    tmp = System.tmp_dir!()
    ws = Path.join(tmp, "pg-gate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(ws, "app/controllers"))
    File.write!(Path.join(ws, "app/controllers/filter_templates_controller.rb"), "real")

    state_dir = Path.join([ws, "state", "iss-1"])
    File.mkdir_p!(state_dir)

    if plan_body do
      File.write!(Path.join(state_dir, "understanding.md"), plan_body)
    end

    on_exit(fn -> File.rm_rf!(ws) end)
    ws
  end

  describe "enforce/5 — silent pass (gate cannot or should not evaluate)" do
    test "non turn_completed event passes through with the entry unchanged" do
      entry = running_entry(%{workspace_path: "/tmp/whatever"})
      state = empty_state(%{running: %{"issue-pg-1" => entry}})
      update = %{event: :session_started}

      assert {:continue, ^state, ^entry} =
               PlanGroundingGate.enforce(state, "issue-pg-1", entry, update, gate_opts())
    end

    test "turn_count other than 1 passes through" do
      entry = running_entry(%{workspace_path: "/tmp/whatever", turn_count: 2})
      state = empty_state(%{running: %{"issue-pg-1" => entry}})

      assert {:continue, ^state, ^entry} =
               PlanGroundingGate.enforce(state, "issue-pg-1", entry, turn_completed(), gate_opts())
    end

    test "already-checked entry passes through without re-evaluating" do
      entry = running_entry(%{workspace_path: "/tmp/whatever", plan_grounding_checked: true})
      state = empty_state(%{running: %{"issue-pg-1" => entry}})

      assert {:continue, ^state, ^entry} =
               PlanGroundingGate.enforce(state, "issue-pg-1", entry, turn_completed(), gate_opts())
    end

    test "non-binary workspace_path passes through — never false-halts" do
      entry = running_entry(%{workspace_path: nil})
      state = empty_state(%{running: %{"issue-pg-1" => entry}})

      assert {:continue, ^state, ^entry} =
               PlanGroundingGate.enforce(state, "issue-pg-1", entry, turn_completed(), gate_opts())
    end
  end

  describe "enforce/5 — grounded plan" do
    test "a turn-1 understanding.md with a real ## Plan path continues and marks the entry" do
      memory_workflow()

      ws =
        workspace_with("""
        ## Plan

        - `app/controllers/filter_templates_controller.rb` — add promote action
        """)

      entry = running_entry(%{workspace_path: ws})
      state = empty_state(%{running: %{"issue-pg-1" => entry}})

      assert {:continue, ^state, checked_entry} =
               PlanGroundingGate.enforce(state, "issue-pg-1", entry, turn_completed(), gate_opts())

      assert checked_entry.plan_grounding_checked == true
      refute_receive {:terminate_called, _, _}, 100
      refute_receive {:memory_tracker_comment, _, _}, 100
    end
  end

  describe "enforce/5 — ungrounded plan hard halt" do
    test "missing ## Plan section halts: comment, terminate, state move, completed" do
      memory_workflow()

      ws = workspace_with("# Analysis\n\nNo plan section here at all.\n")
      entry = running_entry(%{workspace_path: ws})

      state =
        empty_state(%{
          running: %{"issue-pg-1" => entry},
          claimed: MapSet.new(["issue-pg-1"])
        })

      assert {:halted, halted_state} =
               PlanGroundingGate.enforce(state, "issue-pg-1", entry, turn_completed(), gate_opts())

      assert_receive {:terminate_called, "issue-pg-1", false}, 500

      assert_receive {:memory_tracker_comment, "issue-pg-1", body}, 500
      assert body =~ "Plan-grounding violation"
      assert body =~ "issue parked"
      assert body =~ "ISS-1"

      assert_receive {:memory_tracker_state_update, "issue-pg-1", "On Hold / Blocked"}, 500

      assert MapSet.member?(halted_state.completed, "issue-pg-1")
      refute Map.has_key?(halted_state.running, "issue-pg-1")
      refute MapSet.member?(halted_state.claimed, "issue-pg-1")
    end

    test "a hallucinated path halts and names the offending path in the comment" do
      memory_workflow()

      ws =
        workspace_with("""
        ## Plan

        - `app/controllers/filter_modal_controller.rb` — wrong guess
        """)

      entry = running_entry(%{workspace_path: ws})
      state = empty_state(%{running: %{"issue-pg-1" => entry}})

      assert {:halted, _} =
               PlanGroundingGate.enforce(state, "issue-pg-1", entry, turn_completed(), gate_opts())

      assert_receive {:memory_tracker_comment, "issue-pg-1", body}, 500
      assert body =~ "app/controllers/filter_modal_controller.rb"
    end

    test "a missing understanding.md halts as a missing-plan violation" do
      memory_workflow()

      ws = workspace_with(nil)
      entry = running_entry(%{workspace_path: ws})
      state = empty_state(%{running: %{"issue-pg-1" => entry}})

      assert {:halted, halted_state} =
               PlanGroundingGate.enforce(state, "issue-pg-1", entry, turn_completed(), gate_opts())

      assert_receive {:memory_tracker_comment, "issue-pg-1", body}, 500
      assert body =~ "Plan-grounding violation"
      assert MapSet.member?(halted_state.completed, "issue-pg-1")
    end

    test "skips state move when running_entry.issue is nil but still halts" do
      memory_workflow()

      ws = workspace_with("# Analysis\n\nNo plan.\n")
      entry = running_entry(%{workspace_path: ws, issue: nil})
      state = empty_state(%{running: %{"issue-pg-1" => entry}})

      assert {:halted, halted_state} =
               PlanGroundingGate.enforce(state, "issue-pg-1", entry, turn_completed(), gate_opts())

      assert_receive {:terminate_called, "issue-pg-1", false}, 500
      assert_receive {:memory_tracker_comment, "issue-pg-1", _}, 500
      refute_receive {:memory_tracker_state_update, _, _}, 200

      assert MapSet.member?(halted_state.completed, "issue-pg-1")
    end
  end
end
