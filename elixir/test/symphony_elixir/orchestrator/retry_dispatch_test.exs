defmodule SymphonyElixir.Orchestrator.RetryDispatchTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.{RetryDispatch, State}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Development"],
      tracker_terminal_states: ["Released / Live", "Closed", "Canceled", "Duplicate"],
      tracker_on_pickup_state: "In Development",
      tracker_on_complete_state: "In QA / Review",
      max_concurrent_agents: 5,
      max_concurrent_agents_by_state: %{},
      worker_ssh_hosts: [],
      worker_max_concurrent_agents_per_host: nil
    )

    :ok
  end

  defp build_issue(opts) do
    %Issue{
      id: Keyword.get(opts, :id, "issue-1"),
      identifier: Keyword.get(opts, :identifier, "ISS-1"),
      title: Keyword.get(opts, :title, "test issue"),
      state: Keyword.get(opts, :state, "In Development"),
      has_pr_attachment: Keyword.get(opts, :has_pr_attachment, false),
      assigned_to_worker: Keyword.get(opts, :assigned_to_worker, true),
      assignee_id: Keyword.get(opts, :assignee_id, "worker-id"),
      repos: Keyword.get(opts, :repos, []),
      blocked_by: Keyword.get(opts, :blocked_by, [])
    }
  end

  defp empty_state(overrides \\ %{}) do
    Map.merge(
      %State{
        running: %{},
        claimed: MapSet.new(),
        workpads: %{},
        retry_attempts: %{},
        tick_timer_ref: nil,
        tick_token: nil,
        next_poll_due_at_ms: nil,
        poll_interval_ms: 1,
        max_concurrent_agents: 5
      },
      overrides
    )
  end

  defp record_dispatch(parent) do
    fn state, issue, attempt, worker_host ->
      send(parent, {:dispatch, issue.id, attempt, worker_host})
      state
    end
  end

  defp record_release_claim(parent) do
    fn state, issue_id ->
      send(parent, {:release_claim, issue_id})
      state
    end
  end

  defp base_opts(parent) do
    %{
      recipient: parent,
      dispatch_fn: record_dispatch(parent),
      release_claim_fn: record_release_claim(parent)
    }
  end

  describe "handle_retry_issue/5 — fetch :ok" do
    test "terminal state -> cleanup + release_claim_fn fires (no dispatch)" do
      issue = build_issue(state: "Released / Live")
      state = empty_state()

      opts =
        base_opts(self())
        |> Map.put(:fetch_fn, fn -> {:ok, [issue]} end)

      RetryDispatch.handle_retry_issue(state, "issue-1", 1, %{identifier: "ISS-1"}, opts)

      assert_received {:release_claim, "issue-1"}
      refute_received {:dispatch, _, _, _}
    end

    test "retry candidate with slots available -> dispatch_fn fires" do
      issue = build_issue(state: "In Development")
      state = empty_state()

      opts =
        base_opts(self())
        |> Map.put(:fetch_fn, fn -> {:ok, [issue]} end)

      RetryDispatch.handle_retry_issue(
        state,
        "issue-1",
        2,
        %{identifier: "ISS-1", worker_host: "host-a"},
        opts
      )

      assert_received {:dispatch, "issue-1", 2, "host-a"}
      refute_received {:release_claim, _}
    end

    test "retry candidate with no global slot -> re-arms retry timer" do
      issue = build_issue(state: "In Development")
      # Saturate global slots: 5 max, fill 5 running with a different issue.
      running =
        Enum.into(1..5, %{}, fn i ->
          {"other-#{i}", %{identifier: "OTH-#{i}", issue: build_issue(id: "other-#{i}", identifier: "OTH-#{i}", state: "In Development")}}
        end)

      state = empty_state(%{running: running})

      opts =
        base_opts(self())
        |> Map.put(:fetch_fn, fn -> {:ok, [issue]} end)

      updated =
        RetryDispatch.handle_retry_issue(
          state,
          "issue-1",
          0,
          %{identifier: "ISS-1", delay_type: :continuation},
          opts
        )

      assert %{attempt: 1} = Map.fetch!(updated.retry_attempts, "issue-1")
      assert_receive {:retry_issue, "issue-1", _token}, 2_000
      refute_received {:dispatch, _, _, _}
      refute_received {:release_claim, _}
    end

    test "issue no longer in active/terminal state -> release_claim_fn fires" do
      issue = build_issue(state: "Backlog")
      state = empty_state()

      opts =
        base_opts(self())
        |> Map.put(:fetch_fn, fn -> {:ok, [issue]} end)

      RetryDispatch.handle_retry_issue(state, "issue-1", 1, %{identifier: "ISS-1"}, opts)

      assert_received {:release_claim, "issue-1"}
      refute_received {:dispatch, _, _, _}
    end

    test "issue missing from fetch result -> release_claim_fn fires" do
      state = empty_state()

      opts =
        base_opts(self())
        |> Map.put(:fetch_fn, fn -> {:ok, []} end)

      RetryDispatch.handle_retry_issue(state, "issue-1", 1, %{identifier: "ISS-1"}, opts)

      assert_received {:release_claim, "issue-1"}
      refute_received {:dispatch, _, _, _}
    end
  end

  describe "handle_retry_issue/5 — fetch :error" do
    test "schedules a retry with bumped attempt and error annotation in metadata" do
      state = empty_state()

      opts =
        base_opts(self())
        |> Map.put(:fetch_fn, fn -> {:error, :boom} end)

      updated =
        RetryDispatch.handle_retry_issue(
          state,
          "issue-1",
          2,
          %{identifier: "ISS-1", delay_type: :continuation},
          opts
        )

      assert %{attempt: 3, error: error} = Map.fetch!(updated.retry_attempts, "issue-1")
      assert error =~ "retry poll failed"
      refute_received {:release_claim, _}
      refute_received {:dispatch, _, _, _}
    end
  end

  describe "handle_retry_issue/5 — fetch_fn defaults to Tracker.fetch_candidate_issues/0" do
    test "uses default fetch when :fetch_fn key absent (memory tracker -> {:ok, []})" do
      state = empty_state()
      opts = base_opts(self())

      RetryDispatch.handle_retry_issue(state, "issue-1", 1, %{identifier: "ISS-1"}, opts)

      assert_received {:release_claim, "issue-1"}
    end
  end

  describe "maybe_schedule_continuation_retry/4" do
    test "no PR -> arms continuation retry" do
      state = empty_state()
      issue = build_issue(has_pr_attachment: false)

      running_entry = %{
        identifier: "ISS-1",
        issue: issue,
        retry_attempt: 0,
        worker_host: "host-a",
        workspace_path: "/tmp/ws"
      }

      updated =
        RetryDispatch.maybe_schedule_continuation_retry(
          state,
          "issue-1",
          running_entry,
          base_opts(self())
        )

      assert %{attempt: 1, identifier: "ISS-1", worker_host: "host-a", workspace_path: "/tmp/ws"} =
               Map.fetch!(updated.retry_attempts, "issue-1")

      assert_receive {:retry_issue, "issue-1", _token}, 2_000
    end

    test "PR attached but attempt == 0 -> still arms (one continuation is allowed)" do
      state = empty_state()
      issue = build_issue(has_pr_attachment: true)

      running_entry = %{
        identifier: "ISS-1",
        issue: issue,
        retry_attempt: 0
      }

      updated =
        RetryDispatch.maybe_schedule_continuation_retry(
          state,
          "issue-1",
          running_entry,
          base_opts(self())
        )

      assert Map.has_key?(updated.retry_attempts, "issue-1")
      assert_receive {:retry_issue, "issue-1", _token}, 2_000
    end

    test "PR attached and attempt >= 1 -> capped, returns state unchanged" do
      state = empty_state()
      issue = build_issue(has_pr_attachment: true)

      running_entry = %{
        identifier: "ISS-1",
        issue: issue,
        retry_attempt: 1
      }

      updated =
        RetryDispatch.maybe_schedule_continuation_retry(
          state,
          "issue-1",
          running_entry,
          base_opts(self())
        )

      assert updated == state
      refute Map.has_key?(updated.retry_attempts, "issue-1")
      refute_receive {:retry_issue, _, _}, 200
    end
  end
end
