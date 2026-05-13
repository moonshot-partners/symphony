defmodule SymphonyElixir.AgentRunnerStalePrContinuationTest do
  @moduledoc """
  Regression coverage for SODEV-765: continuation_decision must NOT treat a
  stale closed-not-merged GitHub PR attachment as a completion signal.
  """

  use SymphonyElixir.TestSupport

  defp make_issue(opts \\ []) do
    %Issue{
      id: "issue-765",
      identifier: "SODEV-765",
      title: "Vendor's Dashboard Improvements",
      description: nil,
      url: "https://linear.app/test/SODEV-765",
      state: Keyword.get(opts, :state, "In Development"),
      has_pr_attachment: Keyword.get(opts, :has_pr_attachment, true),
      blocked_by: [],
      repos:
        Keyword.get(opts, :repos, [
          %{name: "schools-out", pr: %{url: "https://github.com/schoolsoutapp/schools-out/pull/693"}}
        ])
    }
  end

  defp configure_active_states do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Development"],
      tracker_terminal_states: ["Released / Live", "Closed", "Canceled", "Duplicate"]
    )
  end

  describe "continuation_decision_for_test/1 — has_pr_attachment=true" do
    test "returns :continue when all attached PRs are closed-not-merged" do
      configure_active_states()
      Application.put_env(:symphony_elixir, :pr_active_check_fn, fn _url -> false end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_active_check_fn) end)

      issue = make_issue()
      assert AgentRunner.continuation_decision_for_test(issue) == :continue
    end

    test "returns :done when any attached PR is OPEN or MERGED" do
      configure_active_states()
      Application.put_env(:symphony_elixir, :pr_active_check_fn, fn _url -> true end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_active_check_fn) end)

      issue = make_issue()
      assert AgentRunner.continuation_decision_for_test(issue) == :done
    end
  end

  describe "continuation_decision_for_test/1 — has_pr_attachment=false" do
    test "returns :continue when state is active and no PR attached" do
      configure_active_states()

      Application.put_env(:symphony_elixir, :pr_active_check_fn, fn _url ->
        raise "should not be called when has_pr_attachment=false"
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_active_check_fn) end)

      issue = make_issue(has_pr_attachment: false, repos: [], state: "Scheduled")
      assert AgentRunner.continuation_decision_for_test(issue) == :continue
    end

    test "returns :done when state is non-active and no PR attached" do
      configure_active_states()
      issue = make_issue(has_pr_attachment: false, repos: [], state: "In QA / Review")
      assert AgentRunner.continuation_decision_for_test(issue) == :done
    end
  end
end
