defmodule SymphonyElixir.Orchestrator.AgentUpdateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator.AgentUpdate

  describe "integrate/2 — token accumulation" do
    test "sums per-event token deltas into running totals" do
      running_entry = %{
        session_id: "sess-1",
        agent_input_tokens: 10,
        agent_output_tokens: 20,
        agent_total_tokens: 30,
        agent_last_reported_input_tokens: 10,
        agent_last_reported_output_tokens: 20,
        agent_last_reported_total_tokens: 30,
        turn_count: 0
      }

      update = %{
        event: :token_usage,
        timestamp: ~U[2026-05-15 13:00:00Z],
        input_tokens: 15,
        output_tokens: 25,
        total_tokens: 40
      }

      {updated, token_delta} = AgentUpdate.integrate(running_entry, update)

      assert token_delta.input_tokens == 5
      assert token_delta.output_tokens == 5
      assert token_delta.total_tokens == 10
      assert updated.agent_input_tokens == 15
      assert updated.agent_output_tokens == 25
      assert updated.agent_total_tokens == 40
      assert updated.agent_last_reported_input_tokens == 15
      assert updated.agent_last_reported_output_tokens == 25
      assert updated.agent_last_reported_total_tokens == 40
    end

    test "uses max() so a smaller payload doesn't roll back last_reported_*" do
      running_entry = %{
        session_id: "sess-1",
        agent_input_tokens: 0,
        agent_output_tokens: 0,
        agent_total_tokens: 0,
        agent_last_reported_input_tokens: 100,
        agent_last_reported_output_tokens: 200,
        agent_last_reported_total_tokens: 300,
        turn_count: 0
      }

      update = %{
        event: :token_usage,
        timestamp: ~U[2026-05-15 13:00:00Z],
        input_tokens: 50,
        output_tokens: 50,
        total_tokens: 50
      }

      {updated, _token_delta} = AgentUpdate.integrate(running_entry, update)

      assert updated.agent_last_reported_input_tokens == 100
      assert updated.agent_last_reported_output_tokens == 200
      assert updated.agent_last_reported_total_tokens == 300
    end
  end

  describe "integrate/2 — agent_pid coercion" do
    test "binary pid passes through" do
      running_entry = base_entry()
      update = base_update() |> Map.put(:agent_pid, "pid-abc")

      {updated, _} = AgentUpdate.integrate(running_entry, update)
      assert updated.agent_pid == "pid-abc"
    end

    test "integer pid is stringified" do
      running_entry = base_entry()
      update = base_update() |> Map.put(:agent_pid, 12_345)

      {updated, _} = AgentUpdate.integrate(running_entry, update)
      assert updated.agent_pid == "12345"
    end

    test "charlist pid is stringified" do
      running_entry = base_entry()
      update = base_update() |> Map.put(:agent_pid, ~c"pid-as-list")

      {updated, _} = AgentUpdate.integrate(running_entry, update)
      assert updated.agent_pid == "pid-as-list"
    end

    test "missing agent_pid in update preserves existing value" do
      running_entry = base_entry() |> Map.put(:agent_pid, "existing-pid")
      update = base_update()

      {updated, _} = AgentUpdate.integrate(running_entry, update)
      assert updated.agent_pid == "existing-pid"
    end
  end

  describe "integrate/2 — session_id propagation" do
    test "binary session_id in update overwrites entry session_id" do
      running_entry = base_entry() |> Map.put(:session_id, "old-sess")
      update = base_update() |> Map.put(:session_id, "new-sess")

      {updated, _} = AgentUpdate.integrate(running_entry, update)
      assert updated.session_id == "new-sess"
    end

    test "missing session_id in update preserves entry session_id" do
      running_entry = base_entry() |> Map.put(:session_id, "keep-sess")
      update = base_update()

      {updated, _} = AgentUpdate.integrate(running_entry, update)
      assert updated.session_id == "keep-sess"
    end
  end

  describe "integrate/2 — turn_count semantics" do
    test "session_started with same session_id keeps existing turn_count" do
      running_entry = base_entry() |> Map.merge(%{session_id: "sess-1", turn_count: 3})

      update = %{
        event: :session_started,
        timestamp: ~U[2026-05-15 13:00:00Z],
        session_id: "sess-1"
      }

      {updated, _} = AgentUpdate.integrate(running_entry, update)
      assert updated.turn_count == 3
    end

    test "session_started with new session_id increments turn_count" do
      running_entry = base_entry() |> Map.merge(%{session_id: "sess-1", turn_count: 3})

      update = %{
        event: :session_started,
        timestamp: ~U[2026-05-15 13:00:00Z],
        session_id: "sess-2"
      }

      {updated, _} = AgentUpdate.integrate(running_entry, update)
      assert updated.turn_count == 4
    end

    test "non-session_started event preserves turn_count" do
      running_entry = base_entry() |> Map.put(:turn_count, 7)
      update = base_update()

      {updated, _} = AgentUpdate.integrate(running_entry, update)
      assert updated.turn_count == 7
    end

    test "missing or non-integer existing turn_count defaults to 0 on non-session_started" do
      running_entry = base_entry() |> Map.put(:turn_count, nil)
      update = base_update()

      {updated, _} = AgentUpdate.integrate(running_entry, update)
      assert updated.turn_count == 0
    end
  end

  describe "integrate/2 — last_agent_* fields" do
    test "records event tag and timestamp" do
      running_entry = base_entry()
      ts = ~U[2026-05-15 14:30:00Z]
      update = %{event: :tool_used, timestamp: ts, payload: "hello"}

      {updated, _} = AgentUpdate.integrate(running_entry, update)

      assert updated.last_agent_timestamp == ts
      assert updated.last_agent_event == :tool_used
      assert updated.last_agent_message == %{event: :tool_used, message: "hello", timestamp: ts}
    end

    test "summary falls back to :raw when :payload missing" do
      running_entry = base_entry()
      ts = ~U[2026-05-15 14:30:00Z]
      update = %{event: :stderr, timestamp: ts, raw: "fallback"}

      {updated, _} = AgentUpdate.integrate(running_entry, update)
      assert updated.last_agent_message == %{event: :stderr, message: "fallback", timestamp: ts}
    end
  end

  defp base_entry do
    %{
      session_id: "sess-1",
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      agent_last_reported_input_tokens: 0,
      agent_last_reported_output_tokens: 0,
      agent_last_reported_total_tokens: 0,
      turn_count: 0
    }
  end

  defp base_update do
    %{event: :tool_used, timestamp: ~U[2026-05-15 13:00:00Z]}
  end
end
