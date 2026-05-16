defmodule SymphonyElixir.Orchestrator.ProcessLivenessTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.ProcessLiveness

  describe "dead_issue_ids/2" do
    test "returns issue_ids whose pid is no longer alive" do
      dead_pid = spawn(fn -> :ok end)
      live_pid = spawn(fn -> Process.sleep(:infinity) end)

      on_exit(fn -> Process.exit(live_pid, :kill) end)

      # Allow the dead process to actually exit before scanning.
      Process.sleep(10)

      running = %{
        "iss-dead" => %{identifier: "SODEV-1", pid: dead_pid},
        "iss-live" => %{identifier: "SODEV-2", pid: live_pid}
      }

      assert ["iss-dead"] = ProcessLiveness.dead_issue_ids(running)
    end

    test "returns empty list when every pid is alive" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)

      running = %{
        "iss-1" => %{identifier: "SODEV-1", pid: pid}
      }

      assert [] = ProcessLiveness.dead_issue_ids(running)
    end

    test "returns empty list for an empty running map" do
      assert [] = ProcessLiveness.dead_issue_ids(%{})
    end

    test "skips entries whose :pid field is missing" do
      running = %{
        "iss-no-pid" => %{identifier: "SODEV-1"}
      }

      # alive_fn must never be invoked when there is no pid.
      alive_fn = fn _pid -> raise "should not be called" end

      assert [] = ProcessLiveness.dead_issue_ids(running, alive_fn)
    end

    test "skips entries whose :pid is not a pid (e.g. nil placeholder)" do
      running = %{
        "iss-nil-pid" => %{identifier: "SODEV-1", pid: nil}
      }

      alive_fn = fn _pid -> raise "should not be called" end

      assert [] = ProcessLiveness.dead_issue_ids(running, alive_fn)
    end

    test "uses the injected alive_fn so tests can simulate dead pids deterministically" do
      pid_dead = spawn(fn -> Process.sleep(:infinity) end)
      pid_live = spawn(fn -> Process.sleep(:infinity) end)

      on_exit(fn ->
        Process.exit(pid_dead, :kill)
        Process.exit(pid_live, :kill)
      end)

      running = %{
        "iss-dead" => %{identifier: "SODEV-1", pid: pid_dead},
        "iss-live" => %{identifier: "SODEV-2", pid: pid_live}
      }

      alive_fn = fn
        ^pid_dead -> false
        ^pid_live -> true
      end

      assert ["iss-dead"] = ProcessLiveness.dead_issue_ids(running, alive_fn)
    end
  end
end
