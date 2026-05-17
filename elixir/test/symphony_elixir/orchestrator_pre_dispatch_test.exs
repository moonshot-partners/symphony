defmodule SymphonyElixir.OrchestratorPreDispatchTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.State

  defp make_issue(opts \\ []) do
    %Issue{
      id: Keyword.get(opts, :id, "issue-pdr-1"),
      identifier: Keyword.get(opts, :identifier, "SODEV-146"),
      title: Keyword.get(opts, :title, "Empty-description issue"),
      description: Keyword.get(opts, :description),
      url: "https://linear.app/test/issue-pdr-1",
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

  describe "handle_pre_dispatch_reject_for_test/4 — on_reject_state configured" do
    test "posts comment + moves issue state + marks issue completed" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_reject_state: "On Hold / Blocked"
      )

      set_memory_tracker_recipient()
      issue = make_issue()
      state = %State{}

      next =
        Orchestrator.handle_pre_dispatch_reject_for_test(
          state,
          issue,
          :empty_description,
          "description is empty — agent cannot extract acceptance criteria."
        )

      assert_receive {:memory_tracker_comment, "issue-pdr-1", body}, 500
      assert body =~ "Pre-dispatch reject"
      assert body =~ "empty_description"
      assert body =~ "description is empty"

      assert_receive {:memory_tracker_state_update, "issue-pdr-1", "On Hold / Blocked"}, 500
      assert MapSet.member?(next.completed, "issue-pdr-1")
    end
  end

  describe "handle_pre_dispatch_reject_for_test/4 — on_reject_state absent" do
    test "still posts comment + marks completed, skips state update" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

      set_memory_tracker_recipient()
      issue = make_issue(id: "issue-pdr-2", identifier: "SODEV-200")
      state = %State{}

      next =
        Orchestrator.handle_pre_dispatch_reject_for_test(
          state,
          issue,
          :empty_description,
          "description is empty."
        )

      assert_receive {:memory_tracker_comment, "issue-pdr-2", _}, 500
      refute_receive {:memory_tracker_state_update, _, _}, 100
      assert MapSet.member?(next.completed, "issue-pdr-2")
    end
  end
end
