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

    deltas =
      Enum.flat_map(baseline, fn b ->
        case Map.fetch(candidates_by_id, b.fixture_id) do
          {:ok, c} -> diff_one(b, c, turn_tol, event_tol_pct)
          :error -> [%{fixture_id: b.fixture_id, field: :missing, baseline: b, candidate: nil}]
        end
      end)

    case deltas do
      [] -> {:ok, []}
      _ -> {:error, deltas}
    end
  end

  defp diff_one(%Result{} = b, %Result{} = c, turn_tol, event_tol_pct) do
    []
    |> maybe_add(b.final_state == c.final_state, %{fixture_id: b.fixture_id, field: :final_state, baseline: b.final_state, candidate: c.final_state})
    |> maybe_add(b.gate_verdicts == c.gate_verdicts, %{fixture_id: b.fixture_id, field: :gate_verdicts, baseline: b.gate_verdicts, candidate: c.gate_verdicts})
    |> maybe_add(b.error_class == c.error_class, %{fixture_id: b.fixture_id, field: :error_class, baseline: b.error_class, candidate: c.error_class})
    |> maybe_add(b.pr_outcome == c.pr_outcome, %{fixture_id: b.fixture_id, field: :pr_outcome, baseline: b.pr_outcome, candidate: c.pr_outcome})
    |> maybe_add(within_int_tolerance?(b.turn_count, c.turn_count, turn_tol), %{fixture_id: b.fixture_id, field: :turn_count, baseline: b.turn_count, candidate: c.turn_count})
    |> maybe_add(within_pct_tolerance?(b.decision_event_count, c.decision_event_count, event_tol_pct), %{
      fixture_id: b.fixture_id,
      field: :decision_event_count,
      baseline: b.decision_event_count,
      candidate: c.decision_event_count
    })
  end

  defp maybe_add(deltas, true, _delta), do: deltas
  defp maybe_add(deltas, false, delta), do: [delta | deltas]

  defp within_int_tolerance?(a, b, tol), do: abs(a - b) <= tol

  defp within_pct_tolerance?(a, b, _pct) when a == 0, do: b == 0
  defp within_pct_tolerance?(a, b, pct), do: abs(b - a) / a * 100 <= pct
end
