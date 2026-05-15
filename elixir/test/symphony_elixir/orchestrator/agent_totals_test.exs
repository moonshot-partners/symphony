defmodule SymphonyElixir.Orchestrator.AgentTotalsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator.AgentTotals

  defp base_state do
    %{
      agent_totals: %{
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        seconds_running: 0
      },
      agent_rate_limits: %{}
    }
  end

  describe "apply_token_delta/2" do
    test "adds input/output/total counters into agent_totals" do
      state =
        base_state()
        |> Map.put(:agent_totals, %{
          input_tokens: 100,
          output_tokens: 200,
          total_tokens: 300,
          seconds_running: 10
        })

      delta = %{input_tokens: 5, output_tokens: 7, total_tokens: 12}

      updated = AgentTotals.apply_token_delta(state, delta)

      assert updated.agent_totals.input_tokens == 105
      assert updated.agent_totals.output_tokens == 207
      assert updated.agent_totals.total_tokens == 312
      assert updated.agent_totals.seconds_running == 10
    end

    test "carries forward seconds_running when present on delta" do
      state = base_state()
      delta = %{input_tokens: 1, output_tokens: 1, total_tokens: 2, seconds_running: 30}

      updated = AgentTotals.apply_token_delta(state, delta)

      assert updated.agent_totals.seconds_running == 30
    end

    test "clamps negative results to 0" do
      state =
        base_state()
        |> Map.put(:agent_totals, %{
          input_tokens: 5,
          output_tokens: 5,
          total_tokens: 5,
          seconds_running: 5
        })

      delta = %{input_tokens: -50, output_tokens: -50, total_tokens: -50, seconds_running: -50}

      updated = AgentTotals.apply_token_delta(state, delta)

      assert updated.agent_totals.input_tokens == 0
      assert updated.agent_totals.output_tokens == 0
      assert updated.agent_totals.total_tokens == 0
      assert updated.agent_totals.seconds_running == 0
    end

    test "no-op when delta missing integer counters" do
      state = base_state()
      delta = %{input_tokens: nil, output_tokens: nil, total_tokens: nil}

      assert AgentTotals.apply_token_delta(state, delta) == state
    end

    test "no-op when delta is not a token-delta map at all" do
      state = base_state()
      assert AgentTotals.apply_token_delta(state, :something_else) == state
    end
  end

  describe "apply_rate_limits/2" do
    test "replaces agent_rate_limits when extractor returns a rate_limits map" do
      state = base_state()

      rate_limits_payload = %{
        "limit_id" => "primary-tokens",
        "primary" => %{"used_percent" => 50.0, "resets_in_seconds" => 600}
      }

      update = %{
        payload: %{
          "method" => "turn/completed",
          "params" => %{"rate_limits" => rate_limits_payload}
        }
      }

      updated = AgentTotals.apply_rate_limits(state, update)

      assert updated.agent_rate_limits == rate_limits_payload
    end

    test "leaves agent_rate_limits untouched when extractor returns nothing usable" do
      state = base_state() |> Map.put(:agent_rate_limits, %{existing: :sentinel})

      assert AgentTotals.apply_rate_limits(state, %{payload: %{}}).agent_rate_limits == %{
               existing: :sentinel
             }
    end

    test "no-op when update is not a map" do
      state = base_state()
      assert AgentTotals.apply_rate_limits(state, nil) == state
    end
  end

  describe "record_session_completion/2" do
    test "rolls runtime_seconds into seconds_running" do
      one_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

      state =
        base_state()
        |> Map.put(:agent_totals, %{
          input_tokens: 10,
          output_tokens: 20,
          total_tokens: 30,
          seconds_running: 100
        })

      running_entry = %{started_at: one_hour_ago}

      updated = AgentTotals.record_session_completion(state, running_entry)

      assert updated.agent_totals.input_tokens == 10
      assert updated.agent_totals.output_tokens == 20
      assert updated.agent_totals.total_tokens == 30
      assert updated.agent_totals.seconds_running >= 100 + 3600
      assert updated.agent_totals.seconds_running <= 100 + 3601
    end

    test "no-op when running_entry is not a map" do
      state = base_state()
      assert AgentTotals.record_session_completion(state, nil) == state
    end
  end

  describe "running_seconds/2" do
    test "returns non-negative whole-second diff" do
      now = ~U[2026-05-15 12:00:00Z]
      started = ~U[2026-05-15 11:00:00Z]

      assert AgentTotals.running_seconds(started, now) == 3600
    end

    test "clamps to 0 when started_at is in the future" do
      now = ~U[2026-05-15 11:00:00Z]
      started = ~U[2026-05-15 12:00:00Z]

      assert AgentTotals.running_seconds(started, now) == 0
    end

    test "non-DateTime args collapse to 0" do
      assert AgentTotals.running_seconds(nil, DateTime.utc_now()) == 0
      assert AgentTotals.running_seconds(DateTime.utc_now(), nil) == 0
      assert AgentTotals.running_seconds(:foo, :bar) == 0
    end
  end
end
