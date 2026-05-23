defmodule SymphonyElixir.OrchestratorPromoteToStagingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.PromoteToStaging

  defp make_issue(opts) do
    repos =
      case Keyword.get(opts, :pr_urls, []) do
        [] -> []
        urls -> Enum.map(urls, fn url -> %{name: "schools-out", pr: %{url: url}} end)
      end

    %Issue{
      id: Keyword.get(opts, :id, "issue-promote"),
      identifier: Keyword.get(opts, :identifier, "SODEV-9999"),
      title: "Test",
      description: nil,
      url: "https://linear.app/test/SODEV-9999",
      state: "Promote to Staging",
      has_pr_attachment: true,
      blocked_by: [],
      repos: repos
    }
  end

  defp set_memory_tracker_recipient do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)
  end

  defp apply_transition(issue, state_name),
    do: TestHooks.apply_state_transition(issue, state_name)

  defp write_promote_workflow! do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_on_complete_state: "In Code Review",
      tracker_on_pr_merge_state: "Ready for QA",
      tracker_on_promote_state: "Promote to Staging"
    )
  end

  describe "PromoteToStaging.reconcile/1" do
    test "green CI + clean review merges PR and routes to on_pr_merge_state" do
      write_promote_workflow!()
      set_memory_tracker_recipient()

      issue = make_issue(id: "iss-merge", pr_urls: ["https://github.com/schoolsoutapp/schools-out/pull/100"])
      merge_calls = :counters.new(1, [:atomics])

      :ok =
        PromoteToStaging.reconcile(
          fetch_fn: fn -> {:ok, [issue]} end,
          status_check_fn: fn _i -> :all_green end,
          review_check_fn: fn _i -> :none end,
          merge_fn: fn _url ->
            :counters.add(merge_calls, 1, 1)
            :ok
          end,
          transition_fn: &apply_transition/2,
          comment_fn: fn _id, _body -> {:ok, "comment-1"} end
        )

      assert_receive {:memory_tracker_state_update, "iss-merge", "Ready for QA"}, 500
      assert :counters.get(merge_calls, 1) == 1
    end

    test "red CI parks issue in on_complete_state with check names in comment" do
      write_promote_workflow!()
      set_memory_tracker_recipient()

      issue = make_issue(id: "iss-red", pr_urls: ["https://github.com/schoolsoutapp/schools-out/pull/101"])
      test_pid = self()

      :ok =
        PromoteToStaging.reconcile(
          fetch_fn: fn -> {:ok, [issue]} end,
          status_check_fn: fn _i -> {:red, ["lint", "test"]} end,
          review_check_fn: fn _i -> :none end,
          merge_fn: fn _url -> flunk("merge_fn must not be called when CI is red") end,
          transition_fn: &apply_transition/2,
          comment_fn: fn id, body ->
            send(test_pid, {:promote_comment, id, body})
            {:ok, "comment-1"}
          end
        )

      assert_receive {:promote_comment, "iss-red", body}, 500
      assert body =~ "CI is red"
      assert body =~ "lint"
      assert body =~ "test"
      assert_receive {:memory_tracker_state_update, "iss-red", "In Code Review"}, 500
    end

    test "request_changes parks issue in on_complete_state with comment" do
      write_promote_workflow!()
      set_memory_tracker_recipient()

      issue = make_issue(id: "iss-rc", pr_urls: ["https://github.com/schoolsoutapp/schools-out/pull/102"])
      test_pid = self()

      :ok =
        PromoteToStaging.reconcile(
          fetch_fn: fn -> {:ok, [issue]} end,
          status_check_fn: fn _i -> :all_green end,
          review_check_fn: fn _i -> {:critical, %{}} end,
          merge_fn: fn _url -> flunk("merge_fn must not be called when review requested changes") end,
          transition_fn: &apply_transition/2,
          comment_fn: fn id, body ->
            send(test_pid, {:promote_comment, id, body})
            {:ok, "comment-1"}
          end
        )

      assert_receive {:promote_comment, "iss-rc", body}, 500
      assert body =~ "claude-pr-review"
      assert_receive {:memory_tracker_state_update, "iss-rc", "In Code Review"}, 500
    end

    test "pending CI is a no-op (no merge, no transition, no comment)" do
      write_promote_workflow!()
      set_memory_tracker_recipient()

      issue = make_issue(id: "iss-pending", pr_urls: ["https://github.com/schoolsoutapp/schools-out/pull/103"])

      :ok =
        PromoteToStaging.reconcile(
          fetch_fn: fn -> {:ok, [issue]} end,
          status_check_fn: fn _i -> :pending end,
          review_check_fn: fn _i -> flunk("review_check_fn must not be called when CI is pending") end,
          merge_fn: fn _url -> flunk("merge_fn must not be called when CI is pending") end,
          transition_fn: &apply_transition/2,
          comment_fn: fn _id, _body -> flunk("comment_fn must not be called when CI is pending") end
        )

      refute_receive {:memory_tracker_state_update, _, _}, 200
    end

    test "no PR attached parks issue in on_complete_state" do
      write_promote_workflow!()
      set_memory_tracker_recipient()

      issue = make_issue(id: "iss-no-pr", pr_urls: [])
      test_pid = self()

      :ok =
        PromoteToStaging.reconcile(
          fetch_fn: fn -> {:ok, [issue]} end,
          status_check_fn: fn _i -> flunk("status_check_fn must not run when no PR") end,
          review_check_fn: fn _i -> flunk("review_check_fn must not run when no PR") end,
          merge_fn: fn _url -> flunk("merge_fn must not run when no PR") end,
          transition_fn: &apply_transition/2,
          comment_fn: fn id, body ->
            send(test_pid, {:promote_comment, id, body})
            {:ok, "comment-1"}
          end
        )

      assert_receive {:promote_comment, "iss-no-pr", body}, 500
      assert body =~ "no PR attached"
      assert_receive {:memory_tracker_state_update, "iss-no-pr", "In Code Review"}, 500
    end

    test "multiple PRs comments unsupported and parks in on_complete_state" do
      write_promote_workflow!()
      set_memory_tracker_recipient()

      urls = [
        "https://github.com/schoolsoutapp/schools-out/pull/200",
        "https://github.com/schoolsoutapp/fe-next-app/pull/201"
      ]

      issue = make_issue(id: "iss-multi", pr_urls: urls)
      test_pid = self()

      :ok =
        PromoteToStaging.reconcile(
          fetch_fn: fn -> {:ok, [issue]} end,
          status_check_fn: fn _i -> flunk("status_check_fn must not run on multi-PR") end,
          review_check_fn: fn _i -> flunk("review_check_fn must not run on multi-PR") end,
          merge_fn: fn _url -> flunk("merge_fn must not run on multi-PR") end,
          transition_fn: &apply_transition/2,
          comment_fn: fn id, body ->
            send(test_pid, {:promote_comment, id, body})
            {:ok, "comment-1"}
          end
        )

      assert_receive {:promote_comment, "iss-multi", body}, 500
      assert body =~ "multi-repo promote is not supported"
      assert body =~ "SYM-12a"
      assert_receive {:memory_tracker_state_update, "iss-multi", "In Code Review"}, 500
    end

    test "merge_fn returning {:error, _} parks issue in on_complete_state" do
      write_promote_workflow!()
      set_memory_tracker_recipient()

      issue = make_issue(id: "iss-merge-fail", pr_urls: ["https://github.com/schoolsoutapp/schools-out/pull/300"])
      test_pid = self()

      :ok =
        PromoteToStaging.reconcile(
          fetch_fn: fn -> {:ok, [issue]} end,
          status_check_fn: fn _i -> :all_green end,
          review_check_fn: fn _i -> :none end,
          merge_fn: fn _url -> {:error, "gh pr merge exit=1"} end,
          transition_fn: &apply_transition/2,
          comment_fn: fn id, body ->
            send(test_pid, {:promote_comment, id, body})
            {:ok, "comment-1"}
          end
        )

      assert_receive {:promote_comment, "iss-merge-fail", body}, 500
      assert body =~ "PR merge failed"
      assert_receive {:memory_tracker_state_update, "iss-merge-fail", "In Code Review"}, 500
    end

    test "no-op when on_promote_state is missing" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_complete_state: "In Code Review",
        tracker_on_pr_merge_state: "Ready for QA"
      )

      set_memory_tracker_recipient()
      called? = :counters.new(1, [:atomics])

      :ok =
        PromoteToStaging.reconcile(
          fetch_fn: fn ->
            :counters.add(called?, 1, 1)
            {:ok, []}
          end,
          status_check_fn: fn _i -> :all_green end,
          review_check_fn: fn _i -> :none end,
          merge_fn: fn _url -> :ok end,
          transition_fn: &apply_transition/2,
          comment_fn: fn _id, _body -> {:ok, "noop"} end
        )

      assert :counters.get(called?, 1) == 0
    end

    test "no-op when on_complete_state is missing" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_pr_merge_state: "Ready for QA",
        tracker_on_promote_state: "Promote to Staging"
      )

      set_memory_tracker_recipient()
      called? = :counters.new(1, [:atomics])

      :ok =
        PromoteToStaging.reconcile(
          fetch_fn: fn ->
            :counters.add(called?, 1, 1)
            {:ok, []}
          end,
          status_check_fn: fn _i -> :all_green end,
          review_check_fn: fn _i -> :none end,
          merge_fn: fn _url -> :ok end,
          transition_fn: &apply_transition/2,
          comment_fn: fn _id, _body -> {:ok, "noop"} end
        )

      assert :counters.get(called?, 1) == 0
    end

    test "no-op when fetch_fn returns {:error, _}" do
      write_promote_workflow!()
      set_memory_tracker_recipient()

      :ok =
        PromoteToStaging.reconcile(
          fetch_fn: fn -> {:error, :upstream_down} end,
          status_check_fn: fn _i -> :all_green end,
          review_check_fn: fn _i -> :none end,
          merge_fn: fn _url -> :ok end,
          transition_fn: &apply_transition/2,
          comment_fn: fn _id, _body -> {:ok, "noop"} end
        )

      refute_receive {:memory_tracker_state_update, _, _}, 200
    end
  end
end
