defmodule SymphonyElixir.Evals.ResultTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Evals.Result

  @sample %Result{
    fixture_id: "01_happy_path",
    final_state: "In Code Review",
    gate_verdicts: [{"gate_c", :pass}, {"gate_d", :pass}],
    turn_count: 2,
    error_class: nil,
    pr_outcome: "merged",
    decision_event_count: 12,
    duration_ms: 137
  }

  test "to_jsonl/1 produces single-line JSON" do
    line = Result.to_jsonl(@sample)
    refute String.contains?(line, "\n")
    decoded = Jason.decode!(line)
    assert decoded["fixture_id"] == "01_happy_path"
    assert decoded["final_state"] == "In Code Review"
    assert decoded["gate_verdicts"] == [["gate_c", "pass"], ["gate_d", "pass"]]
    assert decoded["error_class"] == nil
  end

  test "from_jsonl/1 round-trips" do
    line = Result.to_jsonl(@sample)
    {:ok, decoded} = Result.from_jsonl(line)
    assert decoded == @sample
  end

  test "write_all/2 writes one result per line" do
    path = Path.join(System.tmp_dir!(), "evals_result_test_#{:rand.uniform(1_000_000)}.jsonl")
    Result.write_all([@sample, %{@sample | fixture_id: "02_other"}], path)

    content = File.read!(path)
    assert content |> String.split("\n", trim: true) |> length() == 2

    File.rm!(path)
  end
end
