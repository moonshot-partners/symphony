defmodule SymphonyElixir.OrchestratorStateTransitionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue

  defp make_issue(id \\ "issue-123") do
    %Issue{
      id: id,
      identifier: "SODEV-#{id}",
      title: "Test issue",
      description: nil,
      url: "https://linear.app/test/#{id}",
      state: "Scheduled",
      has_pr_attachment: false,
      blocked_by: []
    }
  end

  defp set_memory_tracker_recipient do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)
  end

  describe "apply_state_transition_for_test/2 — on_pickup_state configured" do
    test "sends state update to tracker with configured state name" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_pickup_state: "In Development"
      )

      set_memory_tracker_recipient()
      issue = make_issue()
      state_name = Config.settings!().tracker.on_pickup_state

      Orchestrator.apply_state_transition_for_test(issue, state_name)

      assert_receive {:memory_tracker_state_update, "issue-123", "In Development"}, 500
    end
  end

  describe "apply_state_transition_for_test/2 — on_pickup_state absent" do
    test "sends no state update when state_name is nil" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      set_memory_tracker_recipient()
      issue = make_issue()
      state_name = Config.settings!().tracker.on_pickup_state

      Orchestrator.apply_state_transition_for_test(issue, state_name)

      refute_receive {:memory_tracker_state_update, _, _}, 100
    end
  end

  describe "apply_state_transition_for_test/2 — on_complete_state configured" do
    test "sends state update to tracker with configured state name" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_complete_state: "In QA / Review"
      )

      set_memory_tracker_recipient()
      issue = make_issue()
      state_name = Config.settings!().tracker.on_complete_state

      Orchestrator.apply_state_transition_for_test(issue, state_name)

      assert_receive {:memory_tracker_state_update, "issue-123", "In QA / Review"}, 500
    end
  end

  describe "apply_state_transition_for_test/2 — on_complete_state absent" do
    test "sends no state update when state_name is nil" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      set_memory_tracker_recipient()
      issue = make_issue()
      state_name = Config.settings!().tracker.on_complete_state

      Orchestrator.apply_state_transition_for_test(issue, state_name)

      refute_receive {:memory_tracker_state_update, _, _}, 100
    end
  end
end
