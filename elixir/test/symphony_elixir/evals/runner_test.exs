defmodule SymphonyElixir.Evals.RunnerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Evals.{Fixture, Result, Runner}

  setup do
    fixtures =
      Map.new(
        ~w(01_sodev_843_default_complete 03_sodev_824_qa_blocked 04_sodev_892_ci_red_scope
           08_sodev_904_not_routable 09_sodev_860_skip_no_critical 10_sodev_146_skip_no_pr),
        fn id -> {id, Fixture.load("../evals/dataset/#{id}.exs")} end
      )

    {:ok, fixtures: fixtures}
  end

  test "run/1 returns a Result with fixture_id matching the fixture", %{fixtures: f} do
    result = Runner.run(f["01_sodev_843_default_complete"])
    assert %Result{fixture_id: "01_sodev_843_default_complete"} = result
  end

  test "run/1 maps default_complete route to In Code Review", %{fixtures: f} do
    result = Runner.run(f["01_sodev_843_default_complete"])
    assert result.final_state == "In Code Review"
    assert result.gate_verdicts == []
    assert result.error_class == nil
    assert result.pr_outcome == "pr_open"
    assert result.turn_count == 3
  end

  test "run/1 maps qa_blocked route to On Hold / Blocked with qa verdict", %{fixtures: f} do
    result = Runner.run(f["03_sodev_824_qa_blocked"])
    assert result.final_state == "On Hold / Blocked"
    assert result.gate_verdicts == [{"qa", :reject}]
    assert result.error_class == :qa_blocked
  end

  test "run/1 maps ci_red route to red_checks gate verdicts", %{fixtures: f} do
    result = Runner.run(f["04_sodev_892_ci_red_scope"])
    assert result.final_state == "On Hold / Blocked"

    assert result.gate_verdicts == [
             {"scope-discipline", :reject},
             {"review", :reject},
             {"review", :reject},
             {"qa-evidence", :reject},
             {"qa-evidence", :reject}
           ]

    assert result.error_class == :ci_red
  end

  test "run/1 maps reconcile terminate not_routable to Backlog", %{fixtures: f} do
    result = Runner.run(f["08_sodev_904_not_routable"])
    assert result.final_state == "Backlog"
    assert result.error_class == :not_routable
    assert result.pr_outcome == "no_pr"
  end

  test "run/1 classifies skip_no_critical when no route happened", %{fixtures: f} do
    result = Runner.run(f["09_sodev_860_skip_no_critical"])
    assert result.error_class == :no_critical
  end

  test "run/1 classifies skip_no_pr when no route happened", %{fixtures: f} do
    result = Runner.run(f["10_sodev_146_skip_no_pr"])
    assert result.error_class == :no_pr
    assert result.pr_outcome == "no_pr"
    assert result.turn_count == 0
  end

  test "run/1 counts decision_event_count from event list length", %{fixtures: f} do
    result = Runner.run(f["04_sodev_892_ci_red_scope"])
    assert result.decision_event_count == 4
  end

  defp synthetic(events, run \\ %{turns: 0, outcome: "no_pr"}) do
    %Fixture{
      id: "synthetic",
      issue: %{state: "In Development"},
      events: events,
      run: run,
      expected: %{}
    }
  end

  test "run/1 classifies terminate non_active_state as :parked" do
    events = [{:reconcile_decision, %{action: "terminate", branch: "non_active_state", linear_state: "On Hold / Blocked"}}]
    result = Runner.run(synthetic(events))
    assert result.final_state == "On Hold / Blocked"
    assert result.error_class == :parked
  end

  test "run/1 classifies terminate terminal_state as :canceled" do
    events = [{:reconcile_decision, %{action: "terminate", branch: "terminal_state", linear_state: "Canceled"}}]
    result = Runner.run(synthetic(events))
    assert result.final_state == "Canceled"
    assert result.error_class == :canceled
  end

  test "run/1 returns nil error_class for unknown terminate branch" do
    events = [{:reconcile_decision, %{action: "terminate", branch: "future_branch", linear_state: "Done"}}]
    result = Runner.run(synthetic(events))
    assert result.error_class == nil
  end

  test "run/1 classifies pr_reengagement_fetch_error as :fetch_error" do
    events = [{:pr_reengagement_fetch_error, %{}}]
    result = Runner.run(synthetic(events))
    assert result.error_class == :fetch_error
  end

  test "run/1 returns nil error_class when events list has no classifiable signal" do
    events = [{:reconcile_decision, %{action: "refresh", branch: "active_state", linear_state: "In Development"}}]
    result = Runner.run(synthetic(events))
    assert result.error_class == nil
  end

  test "run/1 falls back to issue.state when nothing in events sets a final state" do
    result = Runner.run(synthetic([]))
    assert result.final_state == "In Development"
  end
end
