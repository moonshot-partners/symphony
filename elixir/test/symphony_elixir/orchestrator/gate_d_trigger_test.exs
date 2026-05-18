defmodule SymphonyElixir.Orchestrator.GateDTriggerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Orchestrator.GateDTrigger

  describe "maybe_run/1 — session-end AC Evidence gate" do
    test "returns :ok when final turn has ## AC Evidence header" do
      entry = %{
        gate_c_checked: true,
        last_agent_text: "## AC Evidence\n\n- AC 1: found at file.ts:10"
      }

      assert :ok = GateDTrigger.maybe_run(entry)
    end

    test "returns :ok when final turn has ## BLOCKED: header (AC not testable)" do
      entry = %{
        gate_c_checked: true,
        last_agent_text: "## BLOCKED: AC not testable\n\nStaging env unreachable."
      }

      assert :ok = GateDTrigger.maybe_run(entry)
    end

    test "returns {:violation, :missing_header} and logs when header absent" do
      entry = %{
        gate_c_checked: true,
        last_agent_text: "All done! PR created and tests pass.",
        identifier: "SODEV-42"
      }

      log =
        capture_log(fn ->
          assert {:violation, :missing_header} = GateDTrigger.maybe_run(entry)
        end)

      assert log =~ "Gate D violation"
      assert log =~ "SODEV-42"
    end

    test "returns {:violation, :empty_message} and logs when last_agent_text is nil" do
      entry = %{gate_c_checked: true, last_agent_text: nil, identifier: "SODEV-43"}

      capture_log(fn ->
        assert {:violation, :empty_message} = GateDTrigger.maybe_run(entry)
      end)
    end

    test "skips validation and returns :ok when gate_c_checked is false (agent never posted)" do
      entry = %{gate_c_checked: false, last_agent_text: "no evidence here"}

      assert :ok = GateDTrigger.maybe_run(entry)
    end

    test "skips validation and returns :ok when gate_c_checked is missing" do
      entry = %{last_agent_text: "no evidence here"}

      assert :ok = GateDTrigger.maybe_run(entry)
    end
  end
end
