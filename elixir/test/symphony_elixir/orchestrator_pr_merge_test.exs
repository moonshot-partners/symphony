defmodule SymphonyElixir.OrchestratorPrMergeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Linear.Issue, Orchestrator}

  defp make_issue(opts \\ []) do
    repos =
      case Keyword.get(opts, :pr_url) do
        nil -> []
        url -> [%{name: "schools-out", pr: %{url: url}}]
      end

    %Issue{
      id: Keyword.get(opts, :id, "issue-pr-merge"),
      identifier: Keyword.get(opts, :identifier, "SODEV-999"),
      title: "Test",
      description: nil,
      url: "https://linear.app/test/SODEV-999",
      state: "In QA / Review",
      has_pr_attachment: Keyword.get(opts, :has_pr_attachment, true),
      blocked_by: [],
      repos: repos
    }
  end

  defp set_memory_tracker_recipient do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)
  end

  describe "maybe_transition_merged_pr_for_test/3" do
    test "transitions issue when pr_check_fn returns true" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_pr_merge_state: "Released / Live"
      )

      set_memory_tracker_recipient()

      issue = make_issue(pr_url: "https://github.com/schoolsoutapp/schools-out/pull/100")
      Orchestrator.maybe_transition_merged_pr_for_test(issue, "Released / Live", fn _url -> true end)

      assert_receive {:memory_tracker_state_update, "issue-pr-merge", "Released / Live"}, 500
    end

    test "does not transition when pr_check_fn returns false" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_pr_merge_state: "Released / Live"
      )

      set_memory_tracker_recipient()

      issue = make_issue(pr_url: "https://github.com/schoolsoutapp/schools-out/pull/100")
      Orchestrator.maybe_transition_merged_pr_for_test(issue, "Released / Live", fn _url -> false end)

      refute_receive {:memory_tracker_state_update, _, _}, 200
    end

    test "does not transition when issue has no PR URLs" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_pr_merge_state: "Released / Live"
      )

      set_memory_tracker_recipient()

      issue = make_issue()
      Orchestrator.maybe_transition_merged_pr_for_test(issue, "Released / Live", fn _url -> true end)

      refute_receive {:memory_tracker_state_update, _, _}, 200
    end
  end
end
