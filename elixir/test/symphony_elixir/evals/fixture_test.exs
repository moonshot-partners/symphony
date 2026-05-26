defmodule SymphonyElixir.Evals.FixtureTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Evals.Fixture

  @sample_path "../evals/dataset/01_sodev_843_default_complete.exs"

  test "load/1 returns a Fixture struct with id from filename" do
    fixture = Fixture.load(@sample_path)
    assert %Fixture{id: "01_sodev_843_default_complete"} = fixture
  end

  test "load/1 parses the issue snapshot from real SODEV ticket" do
    fixture = Fixture.load(@sample_path)
    assert fixture.issue.identifier == "SODEV-843"
    assert fixture.issue.state == "In Development"
    assert fixture.issue.has_pr_attachment == true
  end

  test "load/1 parses production decisions.jsonl events" do
    fixture = Fixture.load(@sample_path)
    assert is_list(fixture.events)
    refute fixture.events == []
    assert {:reconcile_decision, %{branch: "active_state"}} = hd(fixture.events)
  end

  test "load/1 parses run row from runs.jsonl" do
    fixture = Fixture.load(@sample_path)
    assert fixture.run.turns == 3
    assert fixture.run.outcome == "pr_open"
    assert fixture.run.pr_url =~ "schoolsoutapp/fe-next-app/pull/589"
  end

  test "load/1 parses expected outcomes" do
    fixture = Fixture.load(@sample_path)
    assert fixture.expected.final_state == "In Code Review"
    assert fixture.expected.error_class == nil
    assert fixture.expected.pr_outcome == "pr_open"
  end

  test "load_all/1 loads every .exs file under the given directory, sorted" do
    fixtures = Fixture.load_all("../evals/dataset")
    ids = Enum.map(fixtures, & &1.id)

    assert "01_sodev_843_default_complete" in ids
    assert ids == Enum.sort(ids)
    assert length(fixtures) == 10
  end
end
