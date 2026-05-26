defmodule SymphonyElixir.Evals.DiffTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Evals.{Diff, Result}

  defp r(opts),
    do: struct(Result, [fixture_id: "x", final_state: "In Code Review", gate_verdicts: [], turn_count: 1, error_class: nil, pr_outcome: "merged", decision_event_count: 5, duration_ms: 10] ++ opts)

  test "compare/2 returns :ok when results match" do
    assert Diff.compare([r([])], [r([])]) == {:ok, []}
  end

  test "compare/2 flags final_state mismatch" do
    assert {:error, deltas} = Diff.compare([r([])], [r(final_state: "On Hold")])
    assert [%{fixture_id: "x", field: :final_state, baseline: "In Code Review", candidate: "On Hold"}] = deltas
  end

  test "compare/2 flags gate_verdicts mismatch" do
    assert {:error, deltas} = Diff.compare([r([])], [r(gate_verdicts: [{"gate_c", :reject}])])
    assert [%{field: :gate_verdicts}] = deltas
  end

  test "compare/2 allows turn_count within tolerance +/-1 by default" do
    assert Diff.compare([r(turn_count: 2)], [r(turn_count: 3)]) == {:ok, []}
    assert Diff.compare([r(turn_count: 2)], [r(turn_count: 1)]) == {:ok, []}
  end

  test "compare/2 flags turn_count outside tolerance" do
    assert {:error, [%{field: :turn_count}]} = Diff.compare([r(turn_count: 2)], [r(turn_count: 5)])
  end

  test "compare/2 flags error_class mismatch" do
    assert {:error, [%{field: :error_class}]} = Diff.compare([r([])], [r(error_class: :ci_red)])
  end

  test "compare/2 flags missing fixtures" do
    assert {:error, [%{fixture_id: "x", field: :missing}]} = Diff.compare([r([])], [])
  end
end
