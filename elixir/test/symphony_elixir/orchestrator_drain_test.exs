defmodule SymphonyElixir.OrchestratorDrainTest do
  @moduledoc """
  Coverage for the deploy-time drain protocol:

    * `sync_drain_status_for_test/3` flips `state.drain` when the deploy
      script touches the sentinel flag, and writes the running snapshot to
      the status file the deploy script polls.
    * `maybe_dispatch_for_test/1` short-circuits while `state.drain == true`
      so no new agents are spawned mid-deploy. Reconciles still run so
      in-flight agents whose PR landed update normally.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State

  defp paths(%{tmp_dir: dir}) do
    %{
      status: Path.join(dir, "status.json"),
      drain_flag: Path.join(dir, "drain.flag")
    }
  end

  @moduletag :tmp_dir

  describe "sync_drain_status_for_test/3" do
    test "flips drain to true when flag file exists", ctx do
      %{drain_flag: drain_flag, status: status} = paths(ctx)
      File.touch!(drain_flag)
      state = %State{running: %{}, drain: false}

      new_state = Orchestrator.sync_drain_status_for_test(state, status, drain_flag)

      assert new_state.drain == true
    end

    test "leaves drain false when flag file is absent", ctx do
      %{drain_flag: drain_flag, status: status} = paths(ctx)
      state = %State{running: %{}, drain: false}

      new_state = Orchestrator.sync_drain_status_for_test(state, status, drain_flag)

      assert new_state.drain == false
    end

    test "writes running ids + drain flag to status file", ctx do
      %{drain_flag: drain_flag, status: status} = paths(ctx)
      File.touch!(drain_flag)

      state = %State{
        running: %{"SODEV-1" => %{}, "SODEV-2" => %{}},
        drain: false
      }

      Orchestrator.sync_drain_status_for_test(state, status, drain_flag)

      decoded = status |> File.read!() |> Jason.decode!()
      assert decoded["drain"] == true
      assert Enum.sort(decoded["running"]) == ["SODEV-1", "SODEV-2"]
    end

    test "status file reflects empty running map", ctx do
      %{drain_flag: drain_flag, status: status} = paths(ctx)
      state = %State{running: %{}, drain: false}

      Orchestrator.sync_drain_status_for_test(state, status, drain_flag)

      decoded = status |> File.read!() |> Jason.decode!()
      assert decoded == %{"drain" => false, "running" => []}
    end
  end

  describe "maybe_dispatch_for_test/1 — drain mode" do
    test "returns state untouched when drain is true and no candidates would change running", _ctx do
      state = %State{
        running: %{},
        drain: true,
        max_concurrent_agents: 5,
        agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      result = Orchestrator.maybe_dispatch_for_test(state)

      assert result.running == %{}
      assert result.drain == true
    end
  end
end
