defmodule SymphonyElixir.Orchestrator.SlotPolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.{SlotPolicy, State}

  defp issue(id, state_name \\ "In Development"),
    do: %Issue{id: id, identifier: "SODEV-#{id}", title: "t", state: state_name}

  defp state(opts \\ []) do
    %State{
      running: Keyword.get(opts, :running, %{}),
      claimed: Keyword.get(opts, :claimed, MapSet.new()),
      max_concurrent_agents: Keyword.get(opts, :max_concurrent_agents, 5)
    }
  end

  describe "available_slots/1" do
    test "returns max_concurrent_agents minus the running count" do
      assert SlotPolicy.available_slots(state(max_concurrent_agents: 4, running: %{"a" => %{}})) == 3
    end

    test "clamps to zero when running count exceeds the cap" do
      running = for i <- 1..10, into: %{}, do: {"iss-#{i}", %{}}
      assert SlotPolicy.available_slots(state(max_concurrent_agents: 2, running: running)) == 0
    end

    test "falls back to the configured Config.settings agent.max_concurrent_agents when the state field is nil" do
      config_max = SymphonyElixir.Config.settings!().agent.max_concurrent_agents
      bare_state = %State{running: %{}, claimed: MapSet.new(), max_concurrent_agents: nil}
      assert SlotPolicy.available_slots(bare_state) == config_max
    end
  end

  describe "state_slots_available?/2" do
    test "returns true when fewer running entries share the issue_state than the configured limit" do
      running = %{"a" => %{issue: issue("a", "In Development")}}
      assert SlotPolicy.state_slots_available?(issue("b", "In Development"), running) == true
    end

    test "returns false for a non-Issue input" do
      assert SlotPolicy.state_slots_available?(:nope, %{}) == false
    end

    test "returns false when running is not a map" do
      assert SlotPolicy.state_slots_available?(issue("a"), :not_a_map) == false
    end

    test "ignores running entries whose payload does not carry an Issue under :issue" do
      running = %{
        "shaped" => %{issue: issue("shaped", "In Development")},
        "raw" => %{pid: self()},
        "non_issue" => %{issue: %{state: "In Development"}}
      }

      assert SlotPolicy.state_slots_available?(issue("new", "In Development"), running) == true
    end
  end

  describe "dispatch_slots_available?/2" do
    test "returns true when both global and per-state caps have slack" do
      assert SlotPolicy.dispatch_slots_available?(issue("a"), state()) == true
    end

    test "returns false when global slots are exhausted" do
      running = for i <- 1..6, into: %{}, do: {"iss-#{i}", %{}}
      assert SlotPolicy.dispatch_slots_available?(issue("z"), state(running: running, max_concurrent_agents: 6)) == false
    end
  end

  describe "should_dispatch?/4" do
    test "rejects when the issue id is already in the claimed set" do
      st = state(claimed: MapSet.new(["a"]))
      refute SlotPolicy.should_dispatch?(issue("a"), st, MapSet.new(["In Development"]), MapSet.new(["Done"]))
    end

    test "rejects when the issue is already running" do
      st = state(running: %{"a" => %{}})
      refute SlotPolicy.should_dispatch?(issue("a"), st, MapSet.new(["In Development"]), MapSet.new(["Done"]))
    end

    test "rejects non-Issue inputs" do
      refute SlotPolicy.should_dispatch?(:not_an_issue, state(), MapSet.new(), MapSet.new())
    end
  end
end
