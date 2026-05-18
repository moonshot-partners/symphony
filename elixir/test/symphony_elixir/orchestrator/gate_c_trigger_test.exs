defmodule SymphonyElixir.Orchestrator.GateCTriggerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Orchestrator.GateCTrigger

  describe "maybe_run/2 — :turn_completed gate" do
    test "no-op when gate_c_checked is already true" do
      entry = %{gate_c_checked: true, turn_count: 1, last_agent_text: "anything"}

      assert {:ok, ^entry} = GateCTrigger.maybe_run(entry, %{event: :turn_completed})
    end

    test "no-op when turn_count is not 1" do
      entry = %{gate_c_checked: false, turn_count: 2, last_agent_text: "## AC Extracted\nx"}

      assert {:ok, ^entry} = GateCTrigger.maybe_run(entry, %{event: :turn_completed})
    end

    test "returns {:ok, updated_entry} when first turn message has valid header" do
      entry = %{turn_count: 1, last_agent_text: "## AC Extracted\nbody"}

      assert {:ok, updated} = GateCTrigger.maybe_run(entry, %{event: :turn_completed})
      assert updated.gate_c_checked == true
    end

    test "returns {{:violation, reason}, updated_entry} and logs when header missing" do
      entry = %{turn_count: 1, last_agent_text: "no header at all", identifier: "SODEV-9"}

      log =
        capture_log(fn ->
          assert {{:violation, :missing_header}, updated} =
                   GateCTrigger.maybe_run(entry, %{event: :turn_completed})

          assert updated.gate_c_checked == true
        end)

      assert log =~ "Gate C violation"
      assert log =~ "SODEV-9"
    end

    test "returns {{:violation, :empty_message}, updated_entry} when message is nil" do
      entry = %{turn_count: 1, last_agent_text: nil, identifier: "SODEV-10"}

      capture_log(fn ->
        assert {{:violation, :empty_message}, updated} =
                 GateCTrigger.maybe_run(entry, %{event: :turn_completed})

        assert updated.gate_c_checked == true
      end)
    end
  end

  describe "maybe_run/2 — non turn_completed event" do
    test "passes the running_entry through unchanged for any other event" do
      entry = %{gate_c_checked: false, turn_count: 1, last_agent_text: "noise"}

      assert {:ok, ^entry} = GateCTrigger.maybe_run(entry, %{event: :other_thing})
      assert {:ok, ^entry} = GateCTrigger.maybe_run(entry, %{})
    end
  end
end
