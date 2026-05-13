defmodule SymphonyElixir.OrchestratorStalePrReconcileTest do
  @moduledoc """
  Regression coverage for the PR-ready completion gate:

    - SODEV-765 (PR #40): a stale closed-not-merged attachment must not
      trigger completion.
    - SODEV-765 follow-up (Gate B): an OPEN PR whose CI checks are failing
      or pending must not trigger completion either — the agent has more
      work to do until CI is green.

  Both scenarios funnel through the same injection point (`:pr_ready_fn`
  returns false), so the existing tests cover both shapes. The new "OPEN +
  CI failing" describe makes the new scenario explicit at test-name level.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State

  defp make_issue(opts \\ []) do
    %Issue{
      id: Keyword.get(opts, :id, "issue-765"),
      identifier: Keyword.get(opts, :identifier, "SODEV-765"),
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

  defp fake_alive_pid do
    {:ok, pid} = Task.start(fn -> Process.sleep(:infinity) end)
    pid
  end

  defp build_running_state(issue) do
    pid = fake_alive_pid()
    ref = Process.monitor(pid)

    running_entry = %{
      pid: pid,
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      retry_attempt: 0,
      turn_count: 0,
      started_at: DateTime.utc_now(),
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0
    }

    state = %State{
      running: %{issue.id => running_entry},
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    {state, pid}
  end

  defp setup_memory_tracker do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :pr_ready_fn)
    end)
  end

  defp configure_active_states do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Development"],
      tracker_terminal_states: ["Released / Live", "Closed", "Canceled", "Duplicate"],
      tracker_on_pickup_state: "In Development",
      tracker_on_complete_state: "In QA / Review"
    )
  end

  describe "reconcile_issue_states_for_test/2 — stale closed-not-merged PR attachment" do
    test "preserves running agent and skips on_complete transition" do
      configure_active_states()
      setup_memory_tracker()
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url -> false end)

      issue = make_issue()
      {state, fake_pid} = build_running_state(issue)

      new_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      assert Map.has_key?(new_state.running, issue.id),
             "Expected #{issue.id} to remain in running map after reconcile with stale PR; got: #{inspect(new_state.running)}"

      refute_receive {:memory_tracker_state_update, _, _}, 200
      Process.exit(fake_pid, :kill)
    end
  end

  describe "reconcile_issue_states_for_test/2 — ready PR attachment (MERGED, or OPEN + CI green)" do
    test "terminates running agent and transitions to on_complete_state" do
      configure_active_states()
      setup_memory_tracker()
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url -> true end)

      issue = make_issue()
      {state, _fake_pid} = build_running_state(issue)

      new_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(new_state.running, issue.id),
             "Expected #{issue.id} to be removed from running map after reconcile with ready PR"

      assert_receive {:memory_tracker_state_update, "issue-765", "In QA / Review"}, 500
    end
  end

  describe "reconcile_issue_states_for_test/2 — OPEN PR with CI failing/pending" do
    test "preserves running agent so it can fix the failing checks" do
      configure_active_states()
      setup_memory_tracker()
      # Same injection point, but the scenario this models is OPEN+CI-red
      # rather than CLOSED-not-merged. ready? returning false keeps the
      # agent alive until checks go green.
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url -> false end)

      issue = make_issue()
      {state, fake_pid} = build_running_state(issue)

      new_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      assert Map.has_key?(new_state.running, issue.id),
             "Expected #{issue.id} to remain in running map while CI is red; got: #{inspect(new_state.running)}"

      refute_receive {:memory_tracker_state_update, _, _}, 200
      Process.exit(fake_pid, :kill)
    end
  end

  describe "reconcile_issue_states_for_test/2 — stale PR + non-active issue state" do
    test "terminates running agent without firing on_complete transition" do
      configure_active_states()
      setup_memory_tracker()
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url -> false end)

      issue = make_issue(state: "In QA / Review")
      {state, _fake_pid} = build_running_state(issue)

      new_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(new_state.running, issue.id),
             "Expected #{issue.id} to be removed from running map when stale PR meets non-active state"

      refute_receive {:memory_tracker_state_update, _, _}, 200
    end
  end

  describe "reconcile_issue_states_for_test/2 — no PR attachment at all" do
    test "leaves issue in running map when active state and no PR attached" do
      configure_active_states()
      setup_memory_tracker()
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url -> raise "should not be called when has_pr_attachment=false" end)

      issue = make_issue(has_pr_attachment: false, repos: [])
      {state, fake_pid} = build_running_state(issue)

      new_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      assert Map.has_key?(new_state.running, issue.id)
      refute_receive {:memory_tracker_state_update, _, _}, 100
      Process.exit(fake_pid, :kill)
    end
  end
end
