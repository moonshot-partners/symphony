defmodule SymphonyElixir.WorkflowStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.WorkflowStore

  defp with_store_path(new_path, fun) do
    pid = Process.whereis(WorkflowStore)
    original_state = :sys.get_state(pid)
    :sys.replace_state(pid, fn state -> %{state | path: new_path} end)

    try do
      fun.(pid)
    after
      :sys.replace_state(pid, fn _ -> original_state end)
    end
  end

  defp make_local_git_with_workflow do
    base = System.tmp_dir!()
    bare = Path.join(base, "store-bare-#{System.unique_integer([:positive])}")
    work = Path.join(base, "store-work-#{System.unique_integer([:positive])}")

    System.cmd("git", ["init", "--bare", bare], stderr_to_stdout: true)
    System.cmd("git", ["clone", bare, work], stderr_to_stdout: true)
    System.cmd("git", ["-C", work, "config", "user.email", "t@t.com"], stderr_to_stdout: true)
    System.cmd("git", ["-C", work, "config", "user.name", "T"], stderr_to_stdout: true)

    workflow_path = Path.join(work, "WORKFLOW.md")
    File.write!(workflow_path, "---\nfoo: bar\n---\n# Test\n")
    System.cmd("git", ["-C", work, "add", "."], stderr_to_stdout: true)
    System.cmd("git", ["-C", work, "commit", "-m", "init"], stderr_to_stdout: true)
    System.cmd("git", ["-C", work, "push", "origin", "HEAD:main"], stderr_to_stdout: true)

    System.cmd("git", ["-C", work, "branch", "--set-upstream-to=origin/main", "main"], stderr_to_stdout: true)

    workflow_path
  end

  describe "handle_info(:git_pull)" do
    test "succeeds silently when git pull exits 0" do
      workflow_path = make_local_git_with_workflow()

      log =
        with_store_path(workflow_path, fn pid ->
          capture_log(fn ->
            send(pid, :git_pull)
            # synchronize: :current call queues after :git_pull
            GenServer.call(pid, :current)
          end)
        end)

      refute log =~ "git pull failed"
    end

    test "logs warning and stays alive when path is not a git repo" do
      dir = Path.join(System.tmp_dir!(), "nogit-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      fake_path = Path.join(dir, "WORKFLOW.md")

      log =
        with_store_path(fake_path, fn pid ->
          capture_log(fn ->
            send(pid, :git_pull)
            GenServer.call(pid, :current)
          end)
        end)

      assert log =~ "git pull failed"
    end
  end
end
