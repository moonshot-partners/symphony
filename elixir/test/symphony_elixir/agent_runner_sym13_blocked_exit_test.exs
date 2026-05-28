defmodule SymphonyElixir.AgentRunnerSym13BlockedExitTest do
  @moduledoc """
  SYM-13 AC1: graceful BLOCKED exit. When the agent's open PR carries
  `- Result: BLOCKED` under `## QA self-review` (an env gap, not a code
  defect), the orchestrator loop must NOT keep burning turns waiting on
  a refresh from `WorkpadPrSync.route_by_qa`. `continuation_decision/1`
  short-circuits to `:done` so `WorkpadPrSync` can re-classify the
  ticket without us first exhausting `max_turns`.
  """

  use SymphonyElixir.TestSupport

  defp make_issue(opts \\ []) do
    %Issue{
      id: "issue-840",
      identifier: "SODEV-840",
      title: "QA blocked by env gap",
      description: nil,
      url: "https://linear.app/test/SODEV-840",
      state: Keyword.get(opts, :state, "In Development"),
      has_pr_attachment: Keyword.get(opts, :has_pr_attachment, true),
      blocked_by: [],
      repos:
        Keyword.get(opts, :repos, [
          %{
            name: "fe-next-app",
            pr: %{url: "https://github.com/schoolsoutapp/fe-next-app/pull/520"}
          }
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

  describe "continuation_decision_for_test/1 — qa_blocked PR" do
    setup do
      configure_active_states()
      :ok
    end

    test "PR with BLOCKED body + green CI → :done (already handled by ready? path)" do
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url -> true end)

      Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> true end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :pr_ready_fn)
        Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn)
      end)

      issue = make_issue()
      assert AgentRunner.continuation_decision_for_test(issue) == :done
    end

    test "PR with BLOCKED body + pending CI → :done (SYM-13 AC1 graceful exit)" do
      # CI still pending — without the SYM-13 short-circuit, today this
      # would return :continue (PR + not-ready + active state) and burn
      # the rest of max_turns even though the agent already knows the
      # env is blocked.
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url -> false end)

      Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> true end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :pr_ready_fn)
        Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn)
      end)

      issue = make_issue()
      assert AgentRunner.continuation_decision_for_test(issue) == :done
    end

    test "PR with non-BLOCKED body + pending CI + active state → :done (wait for CI)" do
      # Pending CI is not actionable by the agent. Stop the continuation loop
      # and let reconciliation resume only if checks turn red.
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url -> false end)

      Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> false end)
      Application.put_env(:symphony_elixir, :pr_required_checks_status_fn, fn _issue -> :pending end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :pr_ready_fn)
        Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn)
        Application.delete_env(:symphony_elixir, :pr_required_checks_status_fn)
      end)

      issue = make_issue()
      assert AgentRunner.continuation_decision_for_test(issue) == :done
    end

    test "PR with non-BLOCKED body + red CI + active state → :continue" do
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url -> false end)

      Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> false end)

      Application.put_env(:symphony_elixir, :pr_required_checks_status_fn, fn _issue ->
        {:red, ["specs / rspec"]}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :pr_ready_fn)
        Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn)
        Application.delete_env(:symphony_elixir, :pr_required_checks_status_fn)
      end)

      issue = make_issue()
      assert AgentRunner.continuation_decision_for_test(issue) == :continue
    end

    test "no PR attached: qa_blocked? not consulted, state-active issue keeps running" do
      # Without a PR there is no `- Result: BLOCKED` line to look at,
      # so the graceful-exit branch must not fire. Inject a raising fn
      # to prove qa_blocked? was never called.
      Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue ->
        raise "qa_blocked? should not be consulted without a PR"
      end)

      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url ->
        raise "ready? should not be consulted without a PR"
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn)
        Application.delete_env(:symphony_elixir, :pr_ready_fn)
      end)

      issue = make_issue(has_pr_attachment: false, repos: [], state: "Scheduled")
      assert AgentRunner.continuation_decision_for_test(issue) == :continue
    end
  end
end
