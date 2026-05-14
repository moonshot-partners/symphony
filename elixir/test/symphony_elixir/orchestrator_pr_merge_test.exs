defmodule SymphonyElixir.OrchestratorPrMergeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Linear.Issue, Orchestrator}
  alias SymphonyElixir.Orchestrator.PrMerge

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

  defp apply_transition(issue, state_name),
    do: Orchestrator.apply_state_transition_for_test(issue, state_name)

  describe "PrMerge.maybe_transition/4" do
    test "transitions issue when pr_check_fn returns true" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_pr_merge_state: "Released / Live"
      )

      set_memory_tracker_recipient()

      issue = make_issue(pr_url: "https://github.com/schoolsoutapp/schools-out/pull/100")
      PrMerge.maybe_transition(issue, "Released / Live", fn _url -> true end, &apply_transition/2)

      assert_receive {:memory_tracker_state_update, "issue-pr-merge", "Released / Live"}, 500
    end

    test "does not transition when pr_check_fn returns false" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_pr_merge_state: "Released / Live"
      )

      set_memory_tracker_recipient()

      issue = make_issue(pr_url: "https://github.com/schoolsoutapp/schools-out/pull/100")
      PrMerge.maybe_transition(issue, "Released / Live", fn _url -> false end, &apply_transition/2)

      refute_receive {:memory_tracker_state_update, _, _}, 200
    end

    test "does not transition when issue has no PR URLs" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_pr_merge_state: "Released / Live"
      )

      set_memory_tracker_recipient()

      issue = make_issue()
      PrMerge.maybe_transition(issue, "Released / Live", fn _url -> true end, &apply_transition/2)

      refute_receive {:memory_tracker_state_update, _, _}, 200
    end
  end
end
