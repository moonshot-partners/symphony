defmodule SymphonyElixir.Orchestrator.WorkerSelectorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.Orchestrator.WorkerSelector

  defp write_workflow!(overrides) do
    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(), overrides)
  end

  describe "select/2 — no hosts configured" do
    test "returns nil when ssh_hosts is empty" do
      write_workflow!(tracker_kind: "memory", worker_ssh_hosts: [])

      assert WorkerSelector.select(%State{}, nil) == nil
      assert WorkerSelector.select(%State{}, "anything") == nil
    end
  end

  describe "select/2 — hosts available" do
    setup do
      write_workflow!(
        tracker_kind: "memory",
        worker_ssh_hosts: ["host-a", "host-b"],
        worker_max_concurrent_agents_per_host: 2
      )

      :ok
    end

    test "returns preferred host when it is in the list and below the limit" do
      state = %State{running: %{}}

      assert WorkerSelector.select(state, "host-b") == "host-b"
    end

    test "falls back to least-loaded host when preferred is nil" do
      state = %State{
        running: %{
          "i1" => %{worker_host: "host-a"},
          "i2" => %{worker_host: "host-a"}
        }
      }

      # host-a saturated (2/2), host-b empty (0/2) — only host-b is available.
      assert WorkerSelector.select(state, nil) == "host-b"
    end

    test "falls back to least-loaded host when preferred is empty string" do
      state = %State{running: %{"i1" => %{worker_host: "host-a"}}}

      assert WorkerSelector.select(state, "") == "host-b"
    end

    test "falls back to least-loaded host when preferred is not in the configured hosts" do
      state = %State{running: %{}}

      # Tie at 0 each: lowest index wins -> "host-a".
      assert WorkerSelector.select(state, "ghost-host") == "host-a"
    end

    test "ignores running entries whose value does not match the worker_host shape" do
      state = %State{
        running: %{
          "i1" => %{worker_host: "host-a"},
          "noise" => %{some_other_field: :foo}
        }
      }

      # host-a has 1 match, host-b has 0; preferred nil -> least loaded = "host-b".
      assert WorkerSelector.select(state, nil) == "host-b"
    end

    test "returns :no_worker_capacity when every host is at the per-host limit" do
      state = %State{
        running: %{
          "i1" => %{worker_host: "host-a"},
          "i2" => %{worker_host: "host-a"},
          "i3" => %{worker_host: "host-b"},
          "i4" => %{worker_host: "host-b"}
        }
      }

      assert WorkerSelector.select(state, nil) == :no_worker_capacity
      assert WorkerSelector.select(state, "host-a") == :no_worker_capacity
    end
  end

  describe "select/2 — no per-host limit configured" do
    setup do
      write_workflow!(
        tracker_kind: "memory",
        worker_ssh_hosts: ["only-host"],
        worker_max_concurrent_agents_per_host: nil
      )

      :ok
    end

    test "any host stays available regardless of running count when limit is nil" do
      state = %State{
        running: %{
          "i1" => %{worker_host: "only-host"},
          "i2" => %{worker_host: "only-host"},
          "i3" => %{worker_host: "only-host"}
        }
      }

      assert WorkerSelector.select(state, nil) == "only-host"
      assert WorkerSelector.select(state, "only-host") == "only-host"
    end
  end

  describe "slots_available?/1 + /2" do
    setup do
      write_workflow!(
        tracker_kind: "memory",
        worker_ssh_hosts: ["h1"],
        worker_max_concurrent_agents_per_host: 1
      )

      :ok
    end

    test "/1 returns true when at least one host has room" do
      assert WorkerSelector.slots_available?(%State{running: %{}}) == true
    end

    test "/1 returns false when every host is saturated" do
      state = %State{running: %{"i1" => %{worker_host: "h1"}}}

      refute WorkerSelector.slots_available?(state)
    end

    test "/2 mirrors /1 and accepts a preferred host" do
      assert WorkerSelector.slots_available?(%State{running: %{}}, "h1") == true
      assert WorkerSelector.slots_available?(%State{running: %{}}, nil) == true

      saturated = %State{running: %{"i1" => %{worker_host: "h1"}}}

      refute WorkerSelector.slots_available?(saturated, "h1")
      refute WorkerSelector.slots_available?(saturated, nil)
    end
  end
end
