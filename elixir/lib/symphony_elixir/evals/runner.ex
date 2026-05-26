defmodule SymphonyElixir.Evals.Runner do
  @moduledoc """
  Replays a single Fixture against a pure-function classifier over the
  production `decisions.jsonl` event vocabulary. v1 does NOT execute the
  orchestrator GenServer, does NOT call real Linear/GH/Anthropic APIs.

  Event vocabulary mirrors what Symphony emits on Hetzner:

    * `{:reconcile_decision, %{action, branch, linear_state}}`
    * `{:workpad_pr_sync_route, %{branch, target_state, red_checks}}`
    * `{:pr_reengagement_skip_no_pr, %{}}`
    * `{:pr_reengagement_skip_no_critical, %{}}`
    * `{:pr_reengagement_fetch_error, %{}}`
    * `{:orchestrator_terminate, %{}}`

  `turn_count` and `pr_outcome` come from `fixture.run` (runs.jsonl row),
  not from the event stream, because Symphony records them at the
  agent-session level rather than the decision-stream level.
  """

  alias SymphonyElixir.Evals.{Fixture, Result}

  @spec run(Fixture.t()) :: Result.t()
  def run(%Fixture{} = fixture) do
    started_at = System.monotonic_time(:millisecond)

    final_state = derive_final_state(fixture.events, fixture.issue.state)
    gate_verdicts = derive_gate_verdicts(fixture.events)
    error_class = derive_error_class(fixture.events)
    duration_ms = System.monotonic_time(:millisecond) - started_at

    %Result{
      fixture_id: fixture.id,
      final_state: final_state,
      gate_verdicts: gate_verdicts,
      turn_count: Map.fetch!(fixture.run, :turns),
      error_class: error_class,
      pr_outcome: Map.fetch!(fixture.run, :outcome),
      decision_event_count: length(fixture.events),
      duration_ms: duration_ms
    }
  end

  defp derive_final_state(events, fallback) do
    Enum.reduce(events, fallback, fn
      {:workpad_pr_sync_route, %{target_state: ts}}, _ -> ts
      {:reconcile_decision, %{action: "terminate", linear_state: ls}}, _ -> ls
      _, acc -> acc
    end)
  end

  defp derive_gate_verdicts(events) do
    case last_route(events) do
      %{branch: "ci_red", red_checks: red} when is_list(red) ->
        Enum.map(red, &{&1, :reject})

      %{branch: "qa_blocked"} ->
        [{"qa", :reject}]

      _ ->
        []
    end
  end

  defp derive_error_class(events) do
    cond do
      route = last_route(events) ->
        case route.branch do
          "default_complete" -> nil
          other -> String.to_atom(other)
        end

      terminate = last_terminate(events) ->
        terminate_class(terminate)

      skip = last_skip(events) ->
        skip

      true ->
        nil
    end
  end

  defp last_route(events) do
    Enum.reduce(events, nil, fn
      {:workpad_pr_sync_route, payload}, _ -> payload
      _, acc -> acc
    end)
  end

  defp last_terminate(events) do
    Enum.reduce(events, nil, fn
      {:reconcile_decision, %{action: "terminate"} = p}, _ -> p
      _, acc -> acc
    end)
  end

  defp last_skip(events) do
    Enum.reduce(events, nil, fn
      {:pr_reengagement_skip_no_pr, _}, _ -> :no_pr
      {:pr_reengagement_skip_no_critical, _}, _ -> :no_critical
      {:pr_reengagement_fetch_error, _}, _ -> :fetch_error
      _, acc -> acc
    end)
  end

  defp terminate_class(%{branch: "not_routable"}), do: :not_routable
  defp terminate_class(%{branch: "non_active_state"}), do: :parked
  defp terminate_class(%{branch: "terminal_state"}), do: :canceled
  defp terminate_class(_), do: nil
end
