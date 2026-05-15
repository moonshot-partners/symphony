defmodule SymphonyElixir.Orchestrator.TickSchedulerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.{State, TickScheduler}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      poll_interval_ms: 12_345,
      max_concurrent_agents: 7
    )

    :ok
  end

  defp empty_state(overrides \\ %{}) do
    Map.merge(
      %State{
        running: %{},
        claimed: MapSet.new(),
        workpads: %{},
        retry_attempts: %{},
        tick_timer_ref: nil,
        tick_token: nil,
        next_poll_due_at_ms: nil,
        poll_interval_ms: 1,
        max_concurrent_agents: 1
      },
      overrides
    )
  end

  describe "schedule_tick/3" do
    test "arms a fresh tick_timer + tick_token and stores next_poll_due_at_ms on the state" do
      state = empty_state()

      now_ms = System.monotonic_time(:millisecond)
      updated = TickScheduler.schedule_tick(state, 0, self())

      assert is_reference(updated.tick_timer_ref)
      assert is_reference(updated.tick_token)
      assert updated.next_poll_due_at_ms >= now_ms

      assert_receive {:tick, tick_token}, 200
      assert tick_token == updated.tick_token
    end

    test "cancels the previous timer reference when one is already armed" do
      previous_ref = Process.send_after(self(), :stale_tick, 50_000)
      state = empty_state(%{tick_timer_ref: previous_ref})

      _updated = TickScheduler.schedule_tick(state, 5, self())
      refute is_integer(Process.read_timer(previous_ref))
      assert_receive {:tick, _token}, 200
    end
  end

  describe "schedule_poll_cycle_start/2" do
    test "delivers :run_poll_cycle to the recipient after the configured delay" do
      assert :ok = TickScheduler.schedule_poll_cycle_start(self(), 1)
      assert_receive :run_poll_cycle, 200
    end

    test "honors a custom delay" do
      assert :ok = TickScheduler.schedule_poll_cycle_start(self(), 0)
      assert_receive :run_poll_cycle, 200
    end
  end

  describe "refresh_runtime_config/1" do
    test "copies poll_interval_ms and max_concurrent_agents from the live workflow config" do
      state = empty_state()
      refreshed = TickScheduler.refresh_runtime_config(state)

      assert refreshed.poll_interval_ms == 12_345
      assert refreshed.max_concurrent_agents == 7
    end
  end
end
