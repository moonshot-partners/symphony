defmodule SymphonyElixir.Orchestrator.RetryPlanTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.RetryPlan

  describe "delay_ms/2" do
    test "returns the continuation delay (1_000 ms) when attempt == 1 and delay_type is :continuation" do
      assert RetryPlan.delay_ms(1, %{delay_type: :continuation}) == 1_000
    end

    test "falls back to failure backoff when attempt > 1 even with delay_type :continuation" do
      assert RetryPlan.delay_ms(2, %{delay_type: :continuation}) == 20_000
    end

    test "uses exponential failure backoff starting at 10_000 ms for attempt 1" do
      assert RetryPlan.delay_ms(1, %{}) == 10_000
      assert RetryPlan.delay_ms(2, %{}) == 20_000
      assert RetryPlan.delay_ms(3, %{}) == 40_000
    end

    test "clamps the failure backoff at the configured max_retry_backoff_ms ceiling" do
      max = SymphonyElixir.Config.settings!().agent.max_retry_backoff_ms
      assert RetryPlan.delay_ms(20, %{}) == max
    end
  end

  describe "normalize_attempt/1" do
    test "passes through positive integers" do
      assert RetryPlan.normalize_attempt(1) == 1
      assert RetryPlan.normalize_attempt(7) == 7
    end

    test "returns 0 for non-positive integers, nil, or non-integer input" do
      assert RetryPlan.normalize_attempt(0) == 0
      assert RetryPlan.normalize_attempt(-3) == 0
      assert RetryPlan.normalize_attempt(nil) == 0
      assert RetryPlan.normalize_attempt("two") == 0
    end
  end

  describe "next_attempt_from_running/1" do
    test "returns attempt + 1 when running entry carries a positive integer retry_attempt" do
      assert RetryPlan.next_attempt_from_running(%{retry_attempt: 2}) == 3
    end

    test "returns nil when retry_attempt is missing, zero, or non-integer" do
      assert RetryPlan.next_attempt_from_running(%{}) == nil
      assert RetryPlan.next_attempt_from_running(%{retry_attempt: 0}) == nil
      assert RetryPlan.next_attempt_from_running(%{retry_attempt: "x"}) == nil
    end
  end

  describe "pick_identifier/3" do
    test "prefers metadata.identifier, then previous_retry.identifier, then issue_id fallback" do
      assert RetryPlan.pick_identifier("iss-1", %{identifier: "PREV"}, %{identifier: "META"}) == "META"
      assert RetryPlan.pick_identifier("iss-1", %{identifier: "PREV"}, %{}) == "PREV"
      assert RetryPlan.pick_identifier("iss-1", %{}, %{}) == "iss-1"
    end
  end

  describe "pick_error/2" do
    test "prefers metadata.error over previous_retry.error" do
      assert RetryPlan.pick_error(%{error: "old"}, %{error: "new"}) == "new"
      assert RetryPlan.pick_error(%{error: "old"}, %{}) == "old"
      assert RetryPlan.pick_error(%{}, %{}) == nil
    end
  end

  describe "pick_worker_host/2 and pick_workspace_path/2" do
    test "fall back from metadata to previous_retry, then nil" do
      assert RetryPlan.pick_worker_host(%{worker_host: "a"}, %{worker_host: "b"}) == "b"
      assert RetryPlan.pick_worker_host(%{worker_host: "a"}, %{}) == "a"
      assert RetryPlan.pick_worker_host(%{}, %{}) == nil

      assert RetryPlan.pick_workspace_path(%{workspace_path: "/old"}, %{workspace_path: "/new"}) == "/new"
      assert RetryPlan.pick_workspace_path(%{workspace_path: "/old"}, %{}) == "/old"
      assert RetryPlan.pick_workspace_path(%{}, %{}) == nil
    end
  end
end
