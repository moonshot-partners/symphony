defmodule SymphonyElixir.OrchestratorRerunTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.State

  # Rerun is the cockpit's "delete prior run, queue a fresh attempt" action. The
  # operator can fire it on any issue the board shows — including one parked in
  # review ("In Code Review") rather than in an active dispatch state. Those
  # issues are exactly the ones a `fetch_candidate_issues` (active-only) lookup
  # never returns, which is what produced the live "Operation failed: 404" on
  # SODEV-430 (sitting in "In Code Review").
  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Development"],
      tracker_in_progress_states: ["In Development"],
      tracker_review_state: "In Code Review",
      tracker_ready_state: "Approved QA",
      tracker_blocked_state: "On Hold / Blocked",
      tracker_terminal_states: ["Released / Live", "Closed", "Canceled"]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    :ok
  end

  test "rerun requeues an issue parked in the review state by moving it to the dispatch state" do
    issue = %Issue{
      id: "issue-cr-1",
      identifier: "SODEV-430",
      title: "Improve Sign-Up Email Validation",
      description: "do the thing",
      state: "In Code Review"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    initial_state = %State{
      claimed: MapSet.new(["issue-cr-1"]),
      completed: MapSet.new(["issue-cr-1"])
    }

    assert {:reply, {:ok, result}, new_state} =
             Orchestrator.handle_call(
               {:rerun_issue, "SODEV-430"},
               {self(), make_ref()},
               initial_state
             )

    assert result.queued == true
    assert result.issue_id == "issue-cr-1"
    assert result.issue_identifier == "SODEV-430"
    assert result.moved_to == "Scheduled"

    # The Linear issue is moved back to the first dispatch state so the next poll
    # picks it up; this is the requeue the cockpit "Rerun" promises.
    assert_received {:memory_tracker_state_update, "issue-cr-1", "Scheduled"}

    # Stale local markers are cleared so the requeued issue is dispatchable again.
    refute MapSet.member?(new_state.claimed, "issue-cr-1")
    refute MapSet.member?(new_state.completed, "issue-cr-1")
  end

  test "rerun returns not_found when the identifier is not on the board" do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    assert {:reply, {:error, :not_found}, _state} =
             Orchestrator.handle_call(
               {:rerun_issue, "SODEV-999"},
               {self(), make_ref()},
               %State{}
             )
  end

  test "rerun propagates a lookup failure instead of masking it as not_found" do
    # A real tracker fetch failure (e.g. missing API token) must surface as an
    # error, not a misleading 404. The Linear adapter short-circuits to
    # {:error, :missing_linear_api_token} when no token is configured.
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: nil,
      tracker_project_slug: "project",
      tracker_active_states: ["Scheduled", "In Development"],
      tracker_review_state: "In Code Review",
      tracker_terminal_states: ["Released / Live", "Closed", "Canceled"]
    )

    assert {:reply, {:error, :missing_linear_api_token}, _state} =
             Orchestrator.handle_call(
               {:rerun_issue, "SODEV-432"},
               {self(), make_ref()},
               %State{}
             )
  end
end
