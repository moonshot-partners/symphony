defmodule SymphonyElixir.Orchestrator.SnapshotTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator.Snapshot

  defp base_state(overrides \\ %{}) do
    %{
      running: %{},
      retry_attempts: %{},
      agent_totals: %{
        input_tokens: 100,
        output_tokens: 200,
        total_tokens: 300,
        seconds_running: 60
      },
      agent_rate_limits: nil,
      poll_check_in_progress: false,
      next_poll_due_at_ms: nil,
      poll_interval_ms: 5_000
    }
    |> Map.merge(overrides)
  end

  describe "build/3" do
    test "produces an empty snapshot when state is empty" do
      now = ~U[2026-05-15 12:00:00Z]
      snap = Snapshot.build(base_state(), now, 1_000)

      assert snap.running == []
      assert snap.retrying == []
      assert snap.agent_totals.total_tokens == 300
      assert snap.rate_limits == nil

      assert snap.polling == %{
               checking?: false,
               next_poll_in_ms: nil,
               poll_interval_ms: 5_000
             }
    end

    test "projects each running entry with derived runtime_seconds" do
      started = ~U[2026-05-15 11:00:00Z]
      now = ~U[2026-05-15 11:30:00Z]

      running = %{
        "iss-1" => %{
          identifier: "TIC-1",
          issue: %{state: "In Development"},
          worker_host: "host-a",
          workspace_path: "/tmp/ws/iss-1",
          session_id: "sess-a",
          agent_pid: "pid-1",
          agent_input_tokens: 10,
          agent_output_tokens: 20,
          agent_total_tokens: 30,
          turn_count: 2,
          started_at: started,
          last_agent_timestamp: now,
          last_agent_message: %{event: :tool_used, message: "hi", timestamp: now},
          last_agent_event: :tool_used
        }
      }

      snap = Snapshot.build(base_state(%{running: running}), now, 0)

      assert [entry] = snap.running
      assert entry.issue_id == "iss-1"
      assert entry.identifier == "TIC-1"
      assert entry.state == "In Development"
      assert entry.worker_host == "host-a"
      assert entry.workspace_path == "/tmp/ws/iss-1"
      assert entry.session_id == "sess-a"
      assert entry.agent_pid == "pid-1"
      assert entry.agent_input_tokens == 10
      assert entry.agent_output_tokens == 20
      assert entry.agent_total_tokens == 30
      assert entry.turn_count == 2
      assert entry.started_at == started
      assert entry.last_agent_event == :tool_used
      assert entry.runtime_seconds == 1_800
    end

    test "defaults missing turn_count to 0" do
      now = ~U[2026-05-15 12:00:00Z]

      running = %{
        "iss-1" => %{
          identifier: "TIC-1",
          issue: %{state: "In Development"},
          session_id: "sess",
          agent_pid: "pid",
          agent_input_tokens: 0,
          agent_output_tokens: 0,
          agent_total_tokens: 0,
          started_at: now,
          last_agent_timestamp: now,
          last_agent_message: nil,
          last_agent_event: nil
        }
      }

      [entry] = Snapshot.build(base_state(%{running: running}), now, 0).running
      assert entry.turn_count == 0
      assert entry.worker_host == nil
      assert entry.workspace_path == nil
    end

    test "projects retry attempts with clamped due_in_ms" do
      now = ~U[2026-05-15 12:00:00Z]

      retry_attempts = %{
        "iss-1" => %{
          attempt: 3,
          due_at_ms: 5_000,
          identifier: "TIC-1",
          error: "boom",
          worker_host: "host-a",
          workspace_path: "/ws/a"
        },
        "iss-2" => %{
          attempt: 1,
          due_at_ms: 100
        }
      }

      snap = Snapshot.build(base_state(%{retry_attempts: retry_attempts}), now, 1_000)

      retrying_by_id = Map.new(snap.retrying, &{&1.issue_id, &1})

      assert retrying_by_id["iss-1"].attempt == 3
      assert retrying_by_id["iss-1"].due_in_ms == 4_000
      assert retrying_by_id["iss-1"].identifier == "TIC-1"
      assert retrying_by_id["iss-1"].error == "boom"

      assert retrying_by_id["iss-2"].attempt == 1
      assert retrying_by_id["iss-2"].due_in_ms == 0
      assert retrying_by_id["iss-2"].identifier == nil
      assert retrying_by_id["iss-2"].error == nil
      assert retrying_by_id["iss-2"].worker_host == nil
      assert retrying_by_id["iss-2"].workspace_path == nil
    end

    test "reports polling.checking? true when a cycle is in progress" do
      state = base_state(%{poll_check_in_progress: true})
      snap = Snapshot.build(state, ~U[2026-05-15 12:00:00Z], 0)
      assert snap.polling.checking? == true
    end

    test "reports next_poll_in_ms relative to monotonic now_ms" do
      state = base_state(%{next_poll_due_at_ms: 10_000})
      snap = Snapshot.build(state, ~U[2026-05-15 12:00:00Z], 7_500)
      assert snap.polling.next_poll_in_ms == 2_500
    end

    test "clamps next_poll_in_ms to 0 when the due timestamp is in the past" do
      state = base_state(%{next_poll_due_at_ms: 100})
      snap = Snapshot.build(state, ~U[2026-05-15 12:00:00Z], 5_000)
      assert snap.polling.next_poll_in_ms == 0
    end

    test "carries forward the live rate_limits snapshot" do
      rate_limits = %{"limit_id" => "primary", "primary" => %{"used_percent" => 33.0}}
      state = base_state(%{agent_rate_limits: rate_limits})
      snap = Snapshot.build(state, ~U[2026-05-15 12:00:00Z], 0)
      assert snap.rate_limits == rate_limits
    end
  end
end
