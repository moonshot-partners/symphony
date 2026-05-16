defmodule SymphonyElixir.Orchestrator.WorkpadPrSyncTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.{State, WorkpadPrSync}

  setup do
    previous_workpad_enabled = Application.get_env(:symphony_elixir, :workpad_enabled)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    Application.put_env(:symphony_elixir, :workpad_enabled, true)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Progress"],
      tracker_terminal_states: ["Closed", "Done", "Cancelled"]
    )

    on_exit(fn ->
      if previous_workpad_enabled do
        Application.put_env(:symphony_elixir, :workpad_enabled, previous_workpad_enabled)
      else
        Application.delete_env(:symphony_elixir, :workpad_enabled)
      end

      if previous_recipient do
        Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_recipient)
      else
        Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      end
    end)

    :ok
  end

  defp build_state(running, workpads \\ %{}) do
    %State{
      running: running,
      claimed: MapSet.new(),
      workpads: workpads,
      retry_attempts: %{},
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  test "returns state unchanged when the issue is not in running" do
    state = build_state(%{})
    assert WorkpadPrSync.sync(state, "missing", self()) == state
  end

  test "schedules a workpad sync with the pr_attached event when comment_id is on the entry" do
    issue_id = "issue-pr-sync-1"

    running = %{
      issue_id => %{
        issue: %Issue{id: issue_id, identifier: "WP-1", state: "Scheduled"},
        identifier: "WP-1",
        workpad_comment_id: "wp-comment-pr-sync-1",
        workspace_path: "/tmp/nonexistent"
      }
    }

    state = build_state(running)

    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    assert_receive {:memory_tracker_comment_update, "wp-comment-pr-sync-1", body}, 1_000
    assert body =~ "PR aberto"
  end

  test "falls back to state.workpads when workpad_comment_id is not on the running entry" do
    issue_id = "issue-pr-sync-2"

    running = %{
      issue_id => %{
        issue: %Issue{id: issue_id, identifier: "WP-2", state: "Scheduled"},
        identifier: "WP-2",
        workspace_path: "/tmp/nonexistent"
      }
    }

    workpads = %{issue_id => "wp-comment-pr-sync-2"}
    state = build_state(running, workpads)

    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    assert_receive {:memory_tracker_comment_update, "wp-comment-pr-sync-2", body}, 1_000
    assert body =~ "PR aberto"
  end

  test "skips the StateTransition/GithubLabel/QaEvidence side-effects when :issue is missing" do
    issue_id = "issue-pr-sync-3"

    running = %{
      issue_id => %{
        identifier: "WP-3",
        workpad_comment_id: "wp-comment-pr-sync-3",
        workspace_path: "/tmp/nonexistent"
      }
    }

    state = build_state(running)

    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    refute_receive {:memory_tracker_state_update, _, _}, 100
  end

  test "passes the workpad comment id to QaEvidence as parent_id" do
    issue_id = "issue-pr-sync-4"

    base = Path.join(System.tmp_dir!(), "wp-prsync-#{System.unique_integer([:positive])}")
    qa_dir = Path.join(base, "fe-next-app/qa-evidence")
    File.mkdir_p!(qa_dir)
    File.write!(Path.join(qa_dir, "01.png"), "fake-png")
    on_exit(fn -> File.rm_rf!(base) end)

    Application.put_env(:symphony_elixir, :qa_evidence_upload_module, __MODULE__.FakeUpload)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :qa_evidence_upload_module) end)

    running = %{
      issue_id => %{
        issue: %Issue{id: issue_id, identifier: "WP-4", state: "Scheduled"},
        identifier: "WP-4",
        workpad_comment_id: "wp-comment-pr-sync-4",
        workspace_path: base
      }
    }

    state = build_state(running)

    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    assert_receive {:memory_tracker_comment_parent, ^issue_id, "wp-comment-pr-sync-4"}, 2_000
  end

  defmodule FakeUpload do
    @moduledoc false
    def upload(path), do: {:ok, "https://uploads.example/#{Path.basename(path)}"}
  end
end
