defmodule SymphonyElixir.GateDTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GateD

  describe "validate_final_turn/1" do
    test "accepts message with '## AC Evidence' header" do
      text = """
      ## AC Evidence

      - AC 1: disabled={!isValid} found at LoginForm.tsx:42, covered by login.test.ts:88
      - AC 2: MAX_RETRIES=3 at auth.ts:17, test auth.spec.ts:112
      """

      assert :ok = GateD.validate_final_turn(text)
    end

    test "accepts message starting with '## BLOCKED:' (agent could not complete ACs)" do
      text = """
      ## BLOCKED: AC not testable

      The AC requires a third-party payment provider that is not accessible in staging.
      """

      assert :ok = GateD.validate_final_turn(text)
    end

    test "accepts header when preceded by whitespace lines" do
      text = "\n\n## AC Evidence\n\n- AC 1: found at file.ts:10\n"
      assert :ok = GateD.validate_final_turn(text)
    end

    test "rejects message without AC Evidence header" do
      text = "I've completed the work and created the PR. All tests pass."
      assert {:violation, :missing_header} = GateD.validate_final_turn(text)
    end

    test "rejects 'AC Trace' freelance header" do
      text = "## AC Trace\n\n- AC 1: done"
      assert {:violation, :missing_header} = GateD.validate_final_turn(text)
    end

    test "rejects inline mention of header (not at line start)" do
      text = "Work done. Note: '## AC Evidence' is required but I skipped it."
      assert {:violation, :missing_header} = GateD.validate_final_turn(text)
    end

    test "rejects nil" do
      assert {:violation, :empty_message} = GateD.validate_final_turn(nil)
    end

    test "rejects empty string" do
      assert {:violation, :empty_message} = GateD.validate_final_turn("")
    end
  end

  describe "log_violation/2" do
    test "emits Logger.warning with identifier and truncated sample" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          GateD.log_violation(
            {:violation, :missing_header},
            %{identifier: "SODEV-999", last_agent_text: "Work done, no evidence section."}
          )
        end)

      assert log =~ "Gate D violation"
      assert log =~ "reason=missing_header"
      assert log =~ "SODEV-999"
    end

    test "handles missing context fields gracefully" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          GateD.log_violation({:violation, :empty_message}, %{})
        end)

      assert log =~ "Gate D violation"
      assert log =~ "reason=empty_message"
      assert log =~ "issue_identifier=(unknown)"
    end

    test "labels empty last_agent_text as (empty)" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          GateD.log_violation(
            {:violation, :missing_header},
            %{identifier: "SODEV-999", last_agent_text: ""}
          )
        end)

      assert log =~ "sample=\"(empty)\""
    end
  end
end
