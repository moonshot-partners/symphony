defmodule SymphonyElixir.Evals.Runner do
  @moduledoc """
  Replays a single Fixture against a pure-function classifier over the
  fixture's event sequence. v1 does NOT execute the orchestrator GenServer,
  does NOT call real Linear/GH/Anthropic APIs. It reduces over fixture.events
  to produce a Result with final_state, gate_verdicts, pr_outcome, etc.

  Captured as v1 tradeoff in the SYM-36 plan: real GenServer replay is a
  follow-up. This still catches event-classification regressions and gives
  CI a sub-second deterministic regression detector.
  """

  alias SymphonyElixir.Evals.{Fixture, Result}

  @spec run(Fixture.t()) :: Result.t()
  def run(%Fixture{} = fixture) do
    started_at = System.monotonic_time(:millisecond)

    gate_verdicts = drain_gate_verdicts(fixture.events)
    final_state = drain_final_state(fixture.events) || fixture.issue.state
    duration_ms = System.monotonic_time(:millisecond) - started_at

    %Result{
      fixture_id: fixture.id,
      final_state: final_state,
      gate_verdicts: gate_verdicts,
      turn_count: count_turns(fixture.events),
      error_class: classify_error(fixture.events),
      pr_outcome: classify_pr_outcome(fixture.events),
      decision_event_count: length(fixture.events),
      duration_ms: duration_ms
    }
  end

  defp drain_gate_verdicts(events) do
    Enum.flat_map(events, fn
      {:gate_c_pass, _} -> [{"gate_c", :pass}]
      {:gate_c_reject, _} -> [{"gate_c", :reject}]
      {:gate_d_pass, _} -> [{"gate_d", :pass}]
      {:gate_d_reject, _} -> [{"gate_d", :reject}]
      _ -> []
    end)
  end

  defp drain_final_state(events) do
    Enum.reduce(events, nil, fn
      {:state_transition, %{to: to}}, _acc -> to
      {:pr_merged, _}, _acc -> "In Code Review"
      {:pr_review_clean, _}, _acc -> "In Code Review"
      {:gate_d_reject, _}, _acc -> "On Hold"
      {:gate_c_reject, _}, _acc -> "On Hold"
      {:ci_red, _}, _acc -> "On Hold"
      {:qa_blocked, _}, _acc -> "On Hold"
      {:exhaust, _}, _acc -> "On Hold"
      _, acc -> acc
    end)
  end

  defp count_turns(events) do
    Enum.count(events, fn
      {:agent_dispatched, _} -> true
      _ -> false
    end)
  end

  defp classify_error(events) do
    Enum.reduce(events, nil, fn
      {:gate_c_reject, _}, _ -> :gate_c_reject
      {:gate_d_reject, _}, _ -> :gate_d_reject
      {:ci_red, _}, _ -> :ci_red
      {:qa_blocked, _}, _ -> :qa_blocked
      {:exhaust, _}, _ -> :exhaust
      {:conflict_disclosure_reject, _}, _ -> :conflict_disclosure_reject
      _, acc -> acc
    end)
  end

  defp classify_pr_outcome(events) do
    cond do
      Enum.any?(events, &match?({:pr_merged, _}, &1)) -> "merged"
      Enum.any?(events, &match?({:pr_closed_unmerged, _}, &1)) -> "closed_unmerged"
      Enum.any?(events, &match?({:pr_opened, _}, &1)) -> "pr_open"
      Enum.any?(events, &match?({:pr_updated, _}, &1)) -> "pr_open"
      true -> "no_pr"
    end
  end
end
