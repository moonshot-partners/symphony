defmodule SymphonyElixir.Orchestrator.TokenMetricsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator.TokenMetrics

  describe "token_delta_guard/3" do
    test "returns :ok when running total has not crossed the threshold" do
      assert TokenMetrics.token_delta_guard(50_000, 0, 150_000) == :ok
    end

    test "returns :ok when running total - baseline is exactly at the threshold" do
      # Strictly greater than the threshold trips the guard.
      assert TokenMetrics.token_delta_guard(150_000, 0, 150_000) == :ok
    end

    test "returns :halt when running total exceeds threshold above baseline" do
      assert {:halt, info} = TokenMetrics.token_delta_guard(150_001, 0, 150_000)
      assert info.delta == 150_001
      assert info.threshold == 150_000
      assert info.running_total == 150_001
      assert info.baseline == 0
    end

    test "baseline subtracts: only the delta since baseline counts" do
      # Baseline 100k means we already burned 100k earlier. Threshold 150k.
      # Running total 240k → delta 140k, still under threshold.
      assert TokenMetrics.token_delta_guard(240_000, 100_000, 150_000) == :ok

      # Same baseline, total 251k → delta 151k → halt.
      assert {:halt, info} = TokenMetrics.token_delta_guard(251_000, 100_000, 150_000)
      assert info.delta == 151_000
    end

    test "uses the documented 150_000 default threshold" do
      assert {:halt, info} = TokenMetrics.token_delta_guard(150_001, 0)
      assert info.threshold == 150_000

      assert TokenMetrics.token_delta_guard(150_000, 0) == :ok
    end

    test "rejects negative baseline (caller bug)" do
      assert_raise FunctionClauseError, fn ->
        TokenMetrics.token_delta_guard(100, -1, 150_000)
      end
    end

    test "rejects negative running_total (caller bug)" do
      assert_raise FunctionClauseError, fn ->
        TokenMetrics.token_delta_guard(-1, 0, 150_000)
      end
    end

    test "rejects non-positive threshold (caller bug)" do
      assert_raise FunctionClauseError, fn ->
        TokenMetrics.token_delta_guard(100, 0, 0)
      end
    end

    test "baseline above running_total clamps delta to zero (no false halt)" do
      # Defensive: if the caller passes a stale baseline larger than current
      # total, the guard MUST NOT halt — running_total going backwards is a
      # caller-side accounting glitch, not a token burn.
      assert TokenMetrics.token_delta_guard(50_000, 100_000, 150_000) == :ok
    end
  end
end
