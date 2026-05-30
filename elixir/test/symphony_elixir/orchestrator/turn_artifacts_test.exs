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

  describe "maybe_post/3 — understanding.md discovery" do
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

    test "captures understanding.md by log only and keeps Linear quiet" do
      workspace_path = workspace_with_understanding("sess-turn1", "# Ticket Analysis\n\nRoot cause: path alias mismatch.")
      e = entry(%{workspace_path: workspace_path, workpad_comment_id: "wp-comment-1"})

      log =
        capture_log(fn ->
          assert :ok = TurnArtifacts.maybe_post(e, %{event: :turn_completed}, "issue-abc")
          Process.sleep(50)
        end)

      assert log =~ "TurnArtifacts captured understanding.md"
      assert log =~ "SODEV-537"
      refute_receive {:memory_tracker_comment, _, _}, 200
      refute_receive {:memory_tracker_comment_parent, _, _}, 200
    end

    test "skips empty understanding.md" do
      workspace_path = workspace_with_understanding("sess-empty", "")
      e = entry(%{workspace_path: workspace_path})

      log =
        capture_log([level: :debug], fn ->
          assert :ok = TurnArtifacts.maybe_post(e, %{event: :turn_completed}, "issue-abc")
          Process.sleep(50)
        end)

      assert log =~ "understanding.md empty"
      refute_receive {:memory_tracker_comment, _, _}, 200
    end

    test "discovers understanding.md when state dir name differs from session id" do
      workspace_path = workspace_with_understanding("sodev-840", "# Analysis\n\nAgent-written path.")
      e = entry(%{workspace_path: workspace_path, session_id: "shim-dc9fd3b56806-turn-79756d1a87a3"})

      assert :ok = TurnArtifacts.maybe_post(e, %{event: :turn_completed}, "issue-abc")

      assert TurnArtifacts.discover_understanding_md(workspace_path) =~ "state/sodev-840/understanding.md"
      refute_receive {:memory_tracker_comment, _, _}, 200
    end

    test "discovers understanding.md nested under a repo subdir" do
      tmp = System.tmp_dir!()
      uniq = System.unique_integer([:positive])
      workspace_path = Path.join(tmp, "ws-nested-#{uniq}")
      state_dir = Path.join([workspace_path, "fe-next-app", "state", "sodev-891"])
      File.mkdir_p!(state_dir)
      File.write!(Path.join(state_dir, "understanding.md"), "# Analysis\n\nNested under repo subdir.")
      on_exit(fn -> File.rm_rf!(workspace_path) end)

      e = entry(%{workspace_path: workspace_path, session_id: "whatever"})

      assert :ok = TurnArtifacts.maybe_post(e, %{event: :turn_completed}, "issue-abc")

      assert TurnArtifacts.discover_understanding_md(workspace_path) =~
               "fe-next-app/state/sodev-891/understanding.md"

      refute_receive {:memory_tracker_comment, _, _}, 200
    end

    test "ignores understanding.md that is not under a state/ dir" do
      tmp = System.tmp_dir!()
      uniq = System.unique_integer([:positive])
      workspace_path = Path.join(tmp, "ws-nostate-#{uniq}")
      docs_dir = Path.join([workspace_path, "fe-next-app", "docs"])
      File.mkdir_p!(docs_dir)
      File.write!(Path.join(docs_dir, "understanding.md"), "# Repo doc\n\nNot an agent artifact.")
      on_exit(fn -> File.rm_rf!(workspace_path) end)

      e = entry(%{workspace_path: workspace_path, session_id: "whatever"})

      assert :ok = TurnArtifacts.maybe_post(e, %{event: :turn_completed}, "issue-abc")
      assert is_nil(TurnArtifacts.discover_understanding_md(workspace_path))
      refute_receive {:memory_tracker_comment, _, _}, 200
    end

    test "logs debug and skips when the discovered understanding.md is unreadable" do
      tmp = System.tmp_dir!()
      uniq = System.unique_integer([:positive])
      workspace_path = Path.join(tmp, "ws-broken-#{uniq}")
      state_dir = Path.join([workspace_path, "state", "broken"])
      File.mkdir_p!(state_dir)
      File.ln_s!(Path.join(workspace_path, "missing-target"), Path.join(state_dir, "understanding.md"))
      on_exit(fn -> File.rm_rf!(workspace_path) end)

      e = entry(%{workspace_path: workspace_path, session_id: "whatever"})

      log =
        capture_log([level: :debug], fn ->
          assert :ok = TurnArtifacts.maybe_post(e, %{event: :turn_completed}, "issue-abc")
          Process.sleep(50)
        end)

      assert log =~ "understanding.md unreadable"
      refute_receive {:memory_tracker_comment, _, _}, 200
    end

    test "discovers the most-recently-modified understanding.md when multiple state dirs exist" do
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

      assert TurnArtifacts.discover_understanding_md(workspace_path) == new_md
    end
  end

  defp workspace_with_understanding(state_name, content) do
    tmp = System.tmp_dir!()
    uniq = System.unique_integer([:positive])
    workspace_path = Path.join(tmp, "ws-#{state_name}-#{uniq}")
    state_dir = Path.join([workspace_path, "state", state_name])
    File.mkdir_p!(state_dir)
    File.write!(Path.join(state_dir, "understanding.md"), content)
    on_exit(fn -> File.rm_rf!(workspace_path) end)
    workspace_path
  end
end
