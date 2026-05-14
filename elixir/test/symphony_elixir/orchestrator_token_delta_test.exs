defmodule SymphonyElixir.OrchestratorTokenDeltaTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.TokenMetrics

  defp turn_completed_update(usage) do
    payload = %{
      "method" => "turn/completed",
      "params" => %{"turn_id" => "t-1", "usage" => usage}
    }

    %{
      event: :turn_completed,
      timestamp: DateTime.utc_now(),
      payload: payload,
      raw: "",
      details: payload
    }
  end

  describe "TokenMetrics.extract_token_delta/2 — Anthropic SDK usage (no total_tokens)" do
    test "derives total from input + output when total_tokens absent" do
      update = turn_completed_update(%{"input_tokens" => 1000, "output_tokens" => 300})
      delta = TokenMetrics.extract_token_delta(%{}, update)

      assert delta.input_tokens == 1000
      assert delta.output_tokens == 300
      assert delta.total_tokens == 1300
    end

    test "accumulates deltas across successive turns" do
      first = turn_completed_update(%{"input_tokens" => 500, "output_tokens" => 100})
      first_delta = TokenMetrics.extract_token_delta(%{}, first)

      running = %{
        agent_last_reported_input_tokens: first_delta.input_reported,
        agent_last_reported_output_tokens: first_delta.output_reported,
        agent_last_reported_total_tokens: first_delta.total_reported
      }

      second = turn_completed_update(%{"input_tokens" => 800, "output_tokens" => 200})
      second_delta = TokenMetrics.extract_token_delta(running, second)

      assert second_delta.input_tokens == 300
      assert second_delta.output_tokens == 100
      assert second_delta.total_tokens == 400
    end

    test "uses explicit total_tokens when present" do
      update = turn_completed_update(%{"input_tokens" => 1000, "output_tokens" => 300, "total_tokens" => 9999})
      delta = TokenMetrics.extract_token_delta(%{}, update)

      assert delta.total_tokens == 9999
    end

    test "returns zero delta for event without usage payload" do
      update = %{event: :session_started, timestamp: DateTime.utc_now()}
      delta = TokenMetrics.extract_token_delta(%{}, update)

      assert delta.input_tokens == 0
      assert delta.output_tokens == 0
      assert delta.total_tokens == 0
    end
  end
end
