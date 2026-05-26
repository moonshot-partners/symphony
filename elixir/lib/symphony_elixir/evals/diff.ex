defmodule SymphonyElixir.Evals.Diff do
  @moduledoc """
  Structural diff between two `[Result.t()]` collections.

  Invariants checked:
    * final_state exact match
    * gate_verdicts exact match (ordered)
    * error_class exact match
    * pr_outcome exact match
    * turn_count within tolerance (default +/-1)
    * decision_event_count within tolerance (default +/-20%)

  Returns `{:ok, []}` when every fixture passes, `{:error, [delta]}` otherwise.
  """

  alias SymphonyElixir.Evals.Result

  @default_turn_tolerance 1
  @default_event_count_tolerance_pct 20

  @spec compare([Result.t()], [Result.t()], keyword()) :: {:ok, []} | {:error, [map()]}
  def compare(baseline, candidate, opts \\ []) when is_list(baseline) and is_list(candidate) do
    turn_tol = Keyword.get(opts, :turn_tolerance, @default_turn_tolerance)
    event_tol_pct = Keyword.get(opts, :event_count_tolerance_pct, @default_event_count_tolerance_pct)

    candidates_by_id = Map.new(candidate, fn r -> {r.fixture_id, r} end)
    baseline_ids = MapSet.new(baseline, & &1.fixture_id)

    missing_or_changed =
      Enum.flat_map(baseline, fn b ->
        case Map.fetch(candidates_by_id, b.fixture_id) do
          {:ok, c} -> diff_one(b, c, turn_tol, event_tol_pct)
          :error -> [%{fixture_id: b.fixture_id, field: :missing, baseline: b, candidate: nil}]
        end
      end)

    extras =
      candidate
      |> Enum.reject(&MapSet.member?(baseline_ids, &1.fixture_id))
      |> Enum.map(&%{fixture_id: &1.fixture_id, field: :new_in_candidate, baseline: nil, candidate: &1})

    deltas = missing_or_changed ++ extras

    case deltas do
      [] -> {:ok, []}
      _ -> {:error, deltas}
    end
  end

  defp diff_one(%Result{} = b, %Result{} = c, turn_tol, event_tol_pct) do
    bd = b.decision_event_count
    cd = c.decision_event_count

    checks = [
      {b.final_state == c.final_state, :final_state, b.final_state, c.final_state},
      {b.gate_verdicts == c.gate_verdicts, :gate_verdicts, b.gate_verdicts, c.gate_verdicts},
      {b.error_class == c.error_class, :error_class, b.error_class, c.error_class},
      {b.pr_outcome == c.pr_outcome, :pr_outcome, b.pr_outcome, c.pr_outcome},
      {within_int_tolerance?(b.turn_count, c.turn_count, turn_tol), :turn_count, b.turn_count, c.turn_count},
      {within_pct_tolerance?(bd, cd, event_tol_pct), :decision_event_count, bd, cd}
    ]

    for {false, field, base, cand} <- checks do
      %{fixture_id: b.fixture_id, field: field, baseline: base, candidate: cand}
    end
  end

  defp within_int_tolerance?(a, b, tol), do: abs(a - b) <= tol

  defp within_pct_tolerance?(a, b, _pct) when a == 0, do: b == 0
  defp within_pct_tolerance?(a, b, pct), do: abs(b - a) / a * 100 <= pct
end
