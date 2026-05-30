defmodule SymphonyElixir.Orchestrator.CompletionSummaryTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.CompletionSummary

  setup do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :debug_bundle_upload_module, __MODULE__.FakeUpload)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :debug_bundle_upload_module)
      Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_result)
    end)

    :ok
  end

  test "builds ready summary with PR, AC evidence, QA note, and debug bundle" do
    issue = issue()

    running_entry = %{
      pinned_evidence_text: %{
        "AC Evidence" => "## AC Evidence\n\n- AC 1: verified — lib/foo.ex:10"
      }
    }

    body = CompletionSummary.build_comment(issue, "In Code Review", running_entry, :ready_for_review, {:ok, "https://u/debug.zip"})

    assert body =~ "## Ready for review"
    assert body =~ "Moved to `In Code Review` after PR checks and Symphony gates passed."
    assert body =~ "**PR:** https://github.com/org/repo/pull/1"
    assert body =~ "## AC Evidence"
    assert body =~ "screenshots/video/trace are published separately"
    assert body =~ "[agent-debug.zip](https://u/debug.zip)"
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
      body = CompletionSummary.build_comment(issue(%{repos: []}), "On Hold / Blocked", no_ac_entry, reason, {:error, :boom})

      assert body =~ heading
      assert body =~ expected
      assert body =~ "AC evidence:** not captured"
      assert body =~ "Debug bundle:** unavailable (:boom)."
    end)
  end

  test "builds summary without PR metadata and handles malformed reason details" do
    body = CompletionSummary.build_comment(%{}, "Blocked", %{}, {:ci_red, :unknown}, {:error, :boom})

    refute body =~ "**PR:**"
    assert body =~ "required checks are failing: `unknown`"

    body_with_bad_repo =
      CompletionSummary.build_comment(
        issue(%{repos: [%{pr: nil}]}),
        "Done",
        %{},
        :ready_for_review,
        {:ok, "https://u/debug.zip"}
      )

    refute body_with_bad_repo =~ "**PR:**"
  end

  test "truncates long AC evidence in the human summary" do
    text = "## AC Evidence\n\n" <> String.duplicate("verified evidence\n", 400)

    body =
      CompletionSummary.build_comment(
        issue(),
        "In Code Review",
        %{pinned_evidence_text: %{"AC Evidence" => text}},
        :ready_for_review,
        {:ok, "https://u/debug.zip"}
      )

    assert body =~ "(truncated; full text in debug bundle)"
  end

  test "publish posts under the workpad thread" do
    assert :ok = CompletionSummary.publish(issue(), "In Code Review", %{workspace_path: nil}, :ready_for_review, "wp-1")

    assert_receive {:memory_tracker_comment, "issue-1", body}, 1_000
    assert body =~ "## Ready for review"
    assert_receive {:memory_tracker_comment_parent, "issue-1", "wp-1"}, 1_000
  end

  test "publish_async starts the summary task" do
    assert :ok = CompletionSummary.publish_async(issue(), "In Code Review", %{workspace_path: nil}, :ready_for_review, "wp-async")

    assert_receive {:memory_tracker_comment, "issue-1", body}, 1_000
    assert body =~ "## Ready for review"
    assert_receive {:memory_tracker_comment_parent, "issue-1", "wp-async"}, 1_000
  end

  test "publish logs tracker errors without crashing" do
    Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :boom})

    log =
      capture_log([level: :warning], fn ->
        assert :ok = CompletionSummary.publish(issue(), "In Code Review", %{workspace_path: nil}, :ready_for_review, nil)
      end)

    assert log =~ "Completion summary failed"
    assert log =~ "boom"
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

  defmodule FakeUpload do
    @moduledoc false
    def upload(path), do: {:ok, "https://uploads.example/#{Path.basename(path)}"}
  end
end
