defmodule SymphonyElixir.Orchestrator.ArtifactPinTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Orchestrator.ArtifactPin

  setup do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)
    :ok
  end

  defp entry(overrides) do
    base = %{identifier: "SODEV-537", last_agent_text: nil, workpad_comment_id: nil}
    Map.merge(base, overrides)
  end

  describe "pin/3" do
    test "pins the AC Extracted section as a comment threaded under the workpad" do
      text =
        "preamble noise\n\n## AC Extracted\n\n1. Directory renamed\n2. Imports updated\n\n## Notes\n\nignore me"

      e = entry(%{last_agent_text: text, workpad_comment_id: "wp-1"})

      result = ArtifactPin.pin(e, "issue-abc", "AC Extracted")

      assert MapSet.member?(result.pinned_artifacts, "AC Extracted")

      assert_receive {:memory_tracker_comment, "issue-abc", body}, 2000
      assert body =~ "## AC Extracted"
      assert body =~ "1. Directory renamed"
      assert body =~ "2. Imports updated"
      refute body =~ "ignore me"
      refute body =~ "preamble noise"
    end

    test "pins the AC Evidence section" do
      e = entry(%{last_agent_text: "## AC Evidence\n\nAC#1 -> test_foo passes"})

      result = ArtifactPin.pin(e, "issue-abc", "AC Evidence")

      assert MapSet.member?(result.pinned_artifacts, "AC Evidence")

      assert_receive {:memory_tracker_comment, "issue-abc", body}, 2000
      assert body =~ "AC#1 -> test_foo passes"
    end

    test "stores the extracted section text in pinned_evidence_text for downstream gates" do
      # SYM-28: GateDValidator needs the snapshot text durably attached
      # to running_entry — last_agent_text is overwritten every turn, the
      # snapshot must outlive it.
      e = entry(%{last_agent_text: "## AC Evidence\n\n- AC 1: verified — lib/foo.ex:10"})

      result = ArtifactPin.pin(e, "issue-abc", "AC Evidence")

      assert is_map(result.pinned_evidence_text)
      assert result.pinned_evidence_text["AC Evidence"] =~ "AC 1: verified"
      assert result.pinned_evidence_text["AC Evidence"] =~ "## AC Evidence"
    end

    test "repeated calls with the same header pin only once" do
      e = entry(%{last_agent_text: "## AC Extracted\n\nbody"})

      pinned = ArtifactPin.pin(e, "issue-abc", "AC Extracted")
      assert_receive {:memory_tracker_comment, "issue-abc", _}, 2000

      assert ^pinned = ArtifactPin.pin(pinned, "issue-abc", "AC Extracted")
      refute_receive {:memory_tracker_comment, _, _}, 200
    end

    test "different headers are pinned independently on the same entry" do
      text = "## AC Extracted\n\nextracted body\n\n## AC Evidence\n\nevidence body"
      e = entry(%{last_agent_text: text})

      after_extracted = ArtifactPin.pin(e, "issue-abc", "AC Extracted")
      assert_receive {:memory_tracker_comment, "issue-abc", b1}, 2000
      assert b1 =~ "extracted body"

      after_evidence = ArtifactPin.pin(after_extracted, "issue-abc", "AC Evidence")
      assert_receive {:memory_tracker_comment, "issue-abc", b2}, 2000
      assert b2 =~ "evidence body"

      assert MapSet.member?(after_evidence.pinned_artifacts, "AC Extracted")
      assert MapSet.member?(after_evidence.pinned_artifacts, "AC Evidence")
    end

    test "no-op and logs debug when last_agent_text is nil" do
      e = entry(%{last_agent_text: nil})

      log =
        capture_log([level: :debug], fn ->
          assert ^e = ArtifactPin.pin(e, "issue-abc", "AC Extracted")
          Process.sleep(50)
        end)

      assert log =~ "section not found"
      refute_receive {:memory_tracker_comment, _, _}, 200
    end

    test "no-op when the header is absent from the message" do
      e = entry(%{last_agent_text: "## Something Else\n\nno ac here"})

      assert ^e = ArtifactPin.pin(e, "issue-abc", "AC Extracted")

      refute_receive {:memory_tracker_comment, _, _}, 200
    end

    test "posts without parent_id when workpad_comment_id is nil" do
      e = entry(%{last_agent_text: "## AC Extracted\n\nbody", workpad_comment_id: nil})

      ArtifactPin.pin(e, "issue-abc", "AC Extracted")

      assert_receive {:memory_tracker_comment, "issue-abc", body}, 2000
      assert body =~ "## AC Extracted"
    end

    test "logs a warning when Tracker.create_comment returns an error" do
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :boom})
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_result) end)

      e = entry(%{last_agent_text: "## AC Extracted\n\nbody"})

      log =
        capture_log([level: :warning], fn ->
          ArtifactPin.pin(e, "issue-abc", "AC Extracted")
          Process.sleep(100)
        end)

      assert log =~ "ArtifactPin post failed"
      assert log =~ "boom"
    end

    test "section stops at the next ## heading but keeps ### subheadings" do
      text = "## AC Extracted\n\n### Detail\n\nkept content\n\n## AC Evidence\n\ndropped content"
      e = entry(%{last_agent_text: text})

      ArtifactPin.pin(e, "issue-abc", "AC Extracted")

      assert_receive {:memory_tracker_comment, "issue-abc", body}, 2000
      assert body =~ "### Detail"
      assert body =~ "kept content"
      refute body =~ "dropped content"
    end
  end
end
