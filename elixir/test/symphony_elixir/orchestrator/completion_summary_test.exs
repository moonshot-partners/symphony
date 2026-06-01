defmodule SymphonyElixir.Orchestrator.CompletionSummaryTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Cockpit.RunSummaryStore
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.CompletionSummary

  setup do
    root = Path.join(System.tmp_dir!(), "summary-#{System.unique_integer([:positive])}")
    System.put_env("SYMPHONY_COCKPIT_SUMMARY_DIR", root)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    on_exit(fn ->
      System.delete_env("SYMPHONY_COCKPIT_SUMMARY_DIR")
      File.rm_rf!(root)
    end)

    :ok
  end

  describe "build_comment/4" do
    test "builds ready summary with PR, AC evidence, and QA note" do
      issue = issue()

      running_entry = %{
        pinned_evidence_text: %{
          "AC Evidence" => "## AC Evidence\n\n- AC 1: verified — lib/foo.ex:10"
        }
      }

      body = CompletionSummary.build_comment(issue, "In Code Review", running_entry, :ready_for_review)

      assert body =~ "## Ready for review"
      assert body =~ "Moved to `In Code Review` after PR checks and Symphony gates passed."
      assert body =~ "**PR:** https://github.com/org/repo/pull/1"
      assert body =~ "## AC Evidence"
      assert body =~ "screenshots/video are published to the cockpit"
      refute body =~ "debug bundle"
      refute body =~ "agent-debug.zip"
    end

    test "builds blocked summaries for every route reason" do
      no_ac_entry = %{}

      cases = [
        {{:ci_red, ["lint"]}, "## Blocked by CI", "required checks are failing: `lint`"},
        {{:gate_d_substance_fail, [%{ac_id: 2, reason: "missing ref"}]}, "## Blocked by AC evidence", "AC 2 (missing ref)"},
        {{:conflict_disclosure_fail, ["lib/extra.ex"]}, "## Blocked by scope disclosure", "`lib/extra.ex`"},
        {:qa_artifact_missing, "## Blocked by missing visual QA evidence", "QA evidence:** missing"},
        {:qa_blocked, "## Blocked by QA self-review", "reported QA as blocked"}
      ]

      Enum.each(cases, fn {reason, heading, expected} ->
        body = CompletionSummary.build_comment(issue(%{repos: []}), "On Hold / Blocked", no_ac_entry, reason)

        assert body =~ heading
        assert body =~ expected
        assert body =~ "AC evidence:** not captured"
        refute body =~ "agent-debug.zip"
      end)
    end

    test "builds summary without PR metadata and handles malformed reason details" do
      body = CompletionSummary.build_comment(%{}, "Blocked", %{}, {:ci_red, :unknown})

      refute body =~ "**PR:**"
      assert body =~ "required checks are failing: `unknown`"

      body_with_bad_repo =
        CompletionSummary.build_comment(issue(%{repos: [%{pr: nil}]}), "Done", %{}, :ready_for_review)

      refute body_with_bad_repo =~ "**PR:**"
    end

    test "truncates long AC evidence in the summary" do
      text = "## AC Evidence\n\n" <> String.duplicate("verified evidence\n", 400)

      body =
        CompletionSummary.build_comment(
          issue(),
          "In Code Review",
          %{pinned_evidence_text: %{"AC Evidence" => text}},
          :ready_for_review
        )

      assert body =~ "_(truncated)_"
    end
  end

  describe "publish/5" do
    test "stores the summary in the cockpit run summary store, not the tracker" do
      assert :ok =
               CompletionSummary.publish(issue(), "In Code Review", %{workspace_path: nil}, :ready_for_review, "wp-1")

      assert RunSummaryStore.read("issue-1") =~ "## Ready for review"
      # the parent_id arg is ignored; nothing is posted to the tracker
      refute_receive {:memory_tracker_comment, "issue-1", _}, 200
      refute_receive {:memory_tracker_comment_parent, "issue-1", _}, 200
    end

    test "skips the store and logs when the issue id is missing" do
      log =
        capture_log([level: :warning], fn ->
          assert :ok =
                   CompletionSummary.publish(%{identifier: "SYM-44"}, "Blocked", %{}, {:ci_red, ["lint"]}, nil)
        end)

      assert log =~ "Completion summary skipped"
      assert log =~ "SYM-44"
    end
  end

  describe "publish_async/5" do
    test "starts a task that stores the summary" do
      assert :ok =
               CompletionSummary.publish_async(issue(), "In Code Review", %{workspace_path: nil}, :ready_for_review, "wp-async")

      stored =
        Enum.reduce_while(1..100, nil, fn _, _ ->
          case RunSummaryStore.read("issue-1") do
            nil -> Process.sleep(20) && {:cont, nil}
            body -> {:halt, body}
          end
        end)

      assert stored =~ "## Ready for review"
    end
  end

  defp issue(overrides \\ %{}) do
    %Issue{
      id: "issue-1",
      identifier: "SYM-44",
      title: "Clean Linear output",
      repos: [%{name: "symphony", pr: %{url: "https://github.com/org/repo/pull/1"}}]
    }
    |> Map.merge(overrides)
  end
end
