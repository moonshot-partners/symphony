defmodule SymphonyElixir.Orchestrator.TurnArtifactsTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.TurnArtifacts

  setup do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)
    :ok
  end

  defp entry(overrides) do
    base = %{
      identifier: "SODEV-537",
      issue: %Issue{
        id: "issue-abc",
        identifier: "SODEV-537",
        title: "Rename bussines",
        state: "In Development",
        url: "https://linear.app/issues/SODEV-537"
      },
      turn_count: 1,
      session_id: "sess-123",
      workspace_path: nil,
      workpad_comment_id: nil
    }

    Map.merge(base, overrides)
  end

  describe "maybe_post/3 — guard conditions" do
    test "no-op for non turn_completed events" do
      e = entry(%{workspace_path: "/tmp/ws"})

      assert :ok = TurnArtifacts.maybe_post(e, %{event: :session_started}, "issue-abc")
      assert :ok = TurnArtifacts.maybe_post(e, %{event: :pr_attached}, "issue-abc")
      assert :ok = TurnArtifacts.maybe_post(e, %{}, "issue-abc")

      refute_receive {:memory_tracker_comment, _, _}, 200
    end

    test "no-op when turn_count is not 1" do
      e = entry(%{workspace_path: "/tmp/ws", turn_count: 2})

      assert :ok = TurnArtifacts.maybe_post(e, %{event: :turn_completed}, "issue-abc")

      refute_receive {:memory_tracker_comment, _, _}, 200
    end

    test "no-op when workspace_path is missing" do
      e = entry(%{workspace_path: nil})

      assert :ok = TurnArtifacts.maybe_post(e, %{event: :turn_completed}, "issue-abc")

      refute_receive {:memory_tracker_comment, _, _}, 200
    end
  end

  describe "maybe_post/3 — understanding.md not found" do
    test "returns :ok and logs debug when file missing" do
      e = entry(%{workspace_path: "/tmp/no-such-workspace-xyz"})

      log =
        capture_log([level: :debug], fn ->
          assert :ok = TurnArtifacts.maybe_post(e, %{event: :turn_completed}, "issue-abc")
          Process.sleep(50)
        end)

      assert log =~ "understanding.md not found"
      refute_receive {:memory_tracker_comment, _, _}, 200
    end
  end

  describe "maybe_post/3 — understanding.md found" do
    test "posts comment with file contents, threaded under workpad comment when available" do
      tmp = System.tmp_dir!()
      session_id = "sess-turn1-#{System.unique_integer([:positive])}"
      state_dir = Path.join([tmp, "ws-#{session_id}", "state", session_id])
      File.mkdir_p!(state_dir)
      content = "# Ticket Analysis\n\nRoot cause: path alias mismatch."
      File.write!(Path.join(state_dir, "understanding.md"), content)

      workspace_path = Path.join(tmp, "ws-#{session_id}")
      e = entry(%{workspace_path: workspace_path, session_id: session_id, workpad_comment_id: "wp-comment-1"})

      assert :ok = TurnArtifacts.maybe_post(e, %{event: :turn_completed}, "issue-abc")

      assert_receive {:memory_tracker_comment, "issue-abc", body}, 2000
      assert body =~ "understanding.md"
      assert body =~ "SODEV-537"
      assert body =~ "Root cause: path alias mismatch."
    end

    test "posts comment without parent_id when workpad_comment_id is nil" do
      tmp = System.tmp_dir!()
      session_id = "sess-nopid-#{System.unique_integer([:positive])}"
      state_dir = Path.join([tmp, "ws-#{session_id}", "state", session_id])
      File.mkdir_p!(state_dir)
      File.write!(Path.join(state_dir, "understanding.md"), "# Analysis\n\nFoo bar.")

      workspace_path = Path.join(tmp, "ws-#{session_id}")
      e = entry(%{workspace_path: workspace_path, session_id: session_id, workpad_comment_id: nil})

      assert :ok = TurnArtifacts.maybe_post(e, %{event: :turn_completed}, "issue-abc")

      assert_receive {:memory_tracker_comment, "issue-abc", body}, 2000
      assert body =~ "understanding.md"
    end

    test "logs warning when Tracker.create_comment returns error" do
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :boom})
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_result) end)

      tmp = System.tmp_dir!()
      session_id = "sess-err-#{System.unique_integer([:positive])}"
      state_dir = Path.join([tmp, "ws-#{session_id}", "state", session_id])
      File.mkdir_p!(state_dir)
      File.write!(Path.join(state_dir, "understanding.md"), "# Analysis\n\nbody.")

      workspace_path = Path.join(tmp, "ws-#{session_id}")
      e = entry(%{workspace_path: workspace_path, session_id: session_id})

      log =
        capture_log([level: :warning], fn ->
          assert :ok = TurnArtifacts.maybe_post(e, %{event: :turn_completed}, "issue-abc")
          Process.sleep(100)
        end)

      assert log =~ "TurnArtifacts post failed"
      assert log =~ "boom"
    end

    test "skips empty understanding.md" do
      tmp = System.tmp_dir!()
      session_id = "sess-empty-#{System.unique_integer([:positive])}"
      state_dir = Path.join([tmp, "ws-#{session_id}", "state", session_id])
      File.mkdir_p!(state_dir)
      File.write!(Path.join(state_dir, "understanding.md"), "")

      workspace_path = Path.join(tmp, "ws-#{session_id}")
      e = entry(%{workspace_path: workspace_path, session_id: session_id})

      assert :ok = TurnArtifacts.maybe_post(e, %{event: :turn_completed}, "issue-abc")

      refute_receive {:memory_tracker_comment, _, _}, 500
    end

    test "posts when state dir name differs from running_entry session_id (glob discovery)" do
      tmp = System.tmp_dir!()
      uniq = System.unique_integer([:positive])
      workspace_path = Path.join(tmp, "ws-glob-#{uniq}")
      state_dir = Path.join([workspace_path, "state", "sodev-840"])
      File.mkdir_p!(state_dir)
      File.write!(Path.join(state_dir, "understanding.md"), "# Analysis\n\nAgent-written path.")
      on_exit(fn -> File.rm_rf!(workspace_path) end)

      e =
        entry(%{
          workspace_path: workspace_path,
          session_id: "shim-dc9fd3b56806-turn-79756d1a87a3"
        })

      assert :ok = TurnArtifacts.maybe_post(e, %{event: :turn_completed}, "issue-abc")

      assert_receive {:memory_tracker_comment, "issue-abc", body}, 2000
      assert body =~ "Agent-written path."
    end

    test "posts when session_id is missing — session_id is no longer a guard" do
      tmp = System.tmp_dir!()
      uniq = System.unique_integer([:positive])
      workspace_path = Path.join(tmp, "ws-nosid-#{uniq}")
      state_dir = Path.join([workspace_path, "state", "sodev-537"])
      File.mkdir_p!(state_dir)
      File.write!(Path.join(state_dir, "understanding.md"), "# Analysis\n\nNo session id.")
      on_exit(fn -> File.rm_rf!(workspace_path) end)

      e = entry(%{workspace_path: workspace_path, session_id: nil})

      assert :ok = TurnArtifacts.maybe_post(e, %{event: :turn_completed}, "issue-abc")

      assert_receive {:memory_tracker_comment, "issue-abc", body}, 2000
      assert body =~ "No session id."
    end

    test "posts the most-recently-modified understanding.md when multiple state dirs exist" do
      tmp = System.tmp_dir!()
      uniq = System.unique_integer([:positive])
      workspace_path = Path.join(tmp, "ws-multi-#{uniq}")
      old_dir = Path.join([workspace_path, "state", "old-session"])
      new_dir = Path.join([workspace_path, "state", "new-session"])
      File.mkdir_p!(old_dir)
      File.mkdir_p!(new_dir)
      old_md = Path.join(old_dir, "understanding.md")
      new_md = Path.join(new_dir, "understanding.md")
      File.write!(old_md, "# Analysis\n\nStale turn content.")
      File.write!(new_md, "# Analysis\n\nFreshest turn content.")
      File.touch!(old_md, {{2020, 1, 1}, {0, 0, 0}})
      on_exit(fn -> File.rm_rf!(workspace_path) end)

      e = entry(%{workspace_path: workspace_path, session_id: "whatever"})

      assert :ok = TurnArtifacts.maybe_post(e, %{event: :turn_completed}, "issue-abc")

      assert_receive {:memory_tracker_comment, "issue-abc", body}, 2000
      assert body =~ "Freshest turn content."
      refute body =~ "Stale turn content."
    end
  end
end
