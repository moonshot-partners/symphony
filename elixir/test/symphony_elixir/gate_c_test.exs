defmodule SymphonyElixir.GateCTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GateC

  describe "validate_first_turn/1" do
    test "accepts message starting with '## AC Extracted'" do
      text = """
      ## AC Extracted

      1. /vendor/dashboard h1 contains business_name when vendor.approved=true
      2. Footer renders build SHA when QA_BUILD_BADGE=true
      """

      assert :ok = GateC.validate_first_turn(text)
    end

    test "accepts message starting with '## BLOCKED: AC not testable'" do
      text = """
      ## BLOCKED: AC not testable

      The following items cannot be expressed as binary pass/fail:
      - "improve UX"
      """

      assert :ok = GateC.validate_first_turn(text)
    end

    test "accepts header when surrounded by leading whitespace lines" do
      text = "\n\n## AC Extracted\n\n1. something binary\n"
      assert :ok = GateC.validate_first_turn(text)
    end

    test "rejects 'AC Trace' freelance header" do
      text = """
      ## AC Trace

      1. /vendor/dashboard renders the h1
      """

      assert {:violation, :missing_header} = GateC.validate_first_turn(text)
    end

    test "rejects message without any AC header" do
      text = "Sure, I'll start working on this ticket right away."
      assert {:violation, :missing_header} = GateC.validate_first_turn(text)
    end

    test "rejects nil" do
      assert {:violation, :empty_message} = GateC.validate_first_turn(nil)
    end

    test "rejects empty string" do
      assert {:violation, :empty_message} = GateC.validate_first_turn("")
    end

    test "requires header to be at start of a line (rejects inline mentions)" do
      text = "Working on this. Note: '## AC Extracted' is the required header but I won't use it."
      assert {:violation, :missing_header} = GateC.validate_first_turn(text)
    end
  end

  describe "log_violation/2" do
    test "emits a Logger.warning with the issue identifier and a truncated sample" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          GateC.log_violation(
            {:violation, :missing_header},
            %{identifier: "MT-GATE-C", last_agent_text: "## AC Trace\n\n1. nope"}
          )
        end)

      assert log =~ "Gate C violation"
      assert log =~ "reason=missing_header"
      assert log =~ "MT-GATE-C"
      assert log =~ "AC Trace"
    end

    test "handles missing context fields gracefully" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          GateC.log_violation({:violation, :empty_message}, %{})
        end)

      assert log =~ "Gate C violation"
      assert log =~ "reason=empty_message"
      assert log =~ "issue_identifier=(unknown)"
    end
  end
end
