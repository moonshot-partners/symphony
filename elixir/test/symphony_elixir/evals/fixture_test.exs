defmodule SymphonyElixir.Evals.FixtureTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Evals.Fixture

  @sample_path "../evals/dataset/01_happy_path.exs"

  test "load/1 returns a Fixture struct with id from filename" do
    fixture = Fixture.load(@sample_path)
    assert %Fixture{id: "01_happy_path"} = fixture
  end

  test "load/1 parses the issue snapshot" do
    fixture = Fixture.load(@sample_path)
    assert fixture.issue.identifier == "SODEV-839"
    assert fixture.issue.state == "Scheduled"
    assert is_binary(fixture.issue.description)
  end

  test "load/1 parses the planned events sequence" do
    fixture = Fixture.load(@sample_path)
    assert is_list(fixture.events)
    refute fixture.events == []
    assert hd(fixture.events) == {:agent_dispatched, %{turn: 1}}
  end

  test "load/1 parses expected outcomes" do
    fixture = Fixture.load(@sample_path)
    assert fixture.expected.final_state == "In Code Review"
    assert fixture.expected.error_class == nil
    assert fixture.expected.pr_outcome == "merged"
  end
end
