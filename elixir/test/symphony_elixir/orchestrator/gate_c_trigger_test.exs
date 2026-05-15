defmodule SymphonyElixir.Orchestrator.GateCTriggerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Orchestrator.GateCTrigger

  describe "maybe_run/2 — :turn_completed gate" do
    test "no-op when gate_c_checked is already true" do
      entry = %{gate_c_checked: true, turn_count: 1, last_agent_text: "anything"}

      assert GateCTrigger.maybe_run(entry, %{event: :turn_completed}) == entry
    end

    test "no-op when turn_count is not 1" do
      entry = %{gate_c_checked: false, turn_count: 2, last_agent_text: "## AC Extracted\nx"}

      assert GateCTrigger.maybe_run(entry, %{event: :turn_completed}) == entry
    end

    test "marks gate_c_checked=true when first turn message has valid header" do
      entry = %{turn_count: 1, last_agent_text: "## AC Extracted\nbody"}

      result = GateCTrigger.maybe_run(entry, %{event: :turn_completed})

      assert result.gate_c_checked == true
    end

    test "logs violation and still marks gate_c_checked=true when header missing" do
      entry = %{turn_count: 1, last_agent_text: "no header at all", identifier: "SODEV-9"}

      log =
        capture_log(fn ->
          assert %{gate_c_checked: true} =
                   GateCTrigger.maybe_run(entry, %{event: :turn_completed})
        end)

      assert log =~ "Gate C violation"
      assert log =~ "SODEV-9"
    end
  end

  describe "maybe_run/2 — non turn_completed event" do
    test "passes the running_entry through unchanged for any other event" do
      entry = %{gate_c_checked: false, turn_count: 1, last_agent_text: "noise"}

      assert GateCTrigger.maybe_run(entry, %{event: :other_thing}) == entry
      assert GateCTrigger.maybe_run(entry, %{}) == entry
    end
  end
end
