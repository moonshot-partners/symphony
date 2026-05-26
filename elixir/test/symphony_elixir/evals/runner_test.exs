defmodule SymphonyElixir.Evals.RunnerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Evals.{Fixture, Result, Runner}

  setup do
    fixture = Fixture.load("../evals/dataset/01_happy_path.exs")
    {:ok, fixture: fixture}
  end

  test "run/1 returns a Result with fixture_id matching the fixture", %{fixture: fixture} do
    result = Runner.run(fixture)
    assert %Result{fixture_id: "01_happy_path"} = result
  end

  test "run/1 captures the final tracker state", %{fixture: fixture} do
    result = Runner.run(fixture)
    assert result.final_state == "In Code Review"
  end

  test "run/1 captures the gate verdicts emitted during the run", %{fixture: fixture} do
    result = Runner.run(fixture)
    assert result.gate_verdicts == [{"gate_c", :pass}, {"gate_d", :pass}]
  end

  test "run/1 classifies pr_outcome as merged on the happy path", %{fixture: fixture} do
    result = Runner.run(fixture)
    assert result.pr_outcome == "merged"
  end

  test "run/1 sets error_class to nil on the happy path", %{fixture: fixture} do
    result = Runner.run(fixture)
    assert result.error_class == nil
  end
end
