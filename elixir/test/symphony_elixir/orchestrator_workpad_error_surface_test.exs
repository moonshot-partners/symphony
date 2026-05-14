defmodule SymphonyElixir.OrchestratorWorkpadErrorSurfaceTest do
  @moduledoc """
  Regression coverage for SODEV-883 Bug 1: turn_failed error reason must appear
  in the workpad comment body when the orchestrator receives an agent_worker_update
  with event: :turn_failed and a details["error"] string.

  This exercises the full path:
    handle_info(:agent_worker_update)
      → integrate_agent_update
      → Workpad.maybe_sync
      → Workpad.update_last_error_reason
      → Workpad.build_body (includes ### Error section)
      → Tracker.update_comment (memory tracker sends {:memory_tracker_comment_update, ...})

  The workpad_test.exs covers Workpad in isolation. This file proves the orchestrator
  wires the update correctly end-to-end.
  """

  use SymphonyElixir.TestSupport

  setup do
    Application.put_env(:symphony_elixir, :workpad_enabled, true)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :workpad_enabled)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    :ok
  end

  defp start_orchestrator(name) do
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    pid
  end

  defp running_entry(issue_id, comment_id) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: "MT-ERR",
      retry_attempt: 0,
      issue: %Issue{
        id: issue_id,
        identifier: "MT-ERR",
        state: "In Development",
        has_pr_attachment: false
      },
      workpad_comment_id: comment_id,
      session_id: nil,
      last_agent_event: nil,
      last_agent_text: nil,
      last_error_reason: nil,
      turn_count: 1,
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      worker_host: "local",
      workspace_path: "/tmp/ws-test",
      started_at: DateTime.utc_now()
    }
  end

  defp turn_failed_update(error_msg) do
    %{
      event: :turn_failed,
      details: %{"turn_id" => "turn-test-1", "error" => error_msg},
      payload: %{"method" => "turn/failed", "params" => %{}},
      raw: "",
      timestamp: DateTime.utc_now()
    }
  end

  test "turn_failed agent_worker_update renders ### Error in workpad via orchestrator" do
    issue_id = "issue-err-surface-1"
    comment_id = "memory-comment-#{issue_id}"
    error_msg = "You've hit your limit · resets May 16, 2am (UTC)"

    pid = start_orchestrator(Module.concat(__MODULE__, :ErrSurface1))
    initial_state = :sys.get_state(pid)
    entry = running_entry(issue_id, comment_id)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:workpads, %{issue_id => comment_id})
    end)

    send(pid, {:agent_worker_update, issue_id, turn_failed_update(error_msg)})

    assert_receive {:memory_tracker_comment_update, ^comment_id, body}, 1_000
    assert body =~ "### Error", "Expected ### Error section in workpad body"
    assert body =~ error_msg, "Expected error message in workpad body"
    assert body =~ "MT-ERR", "Expected issue identifier in body"
  end

  test "turn_failed error reason surfaces again on subsequent turn_completed sync" do
    issue_id = "issue-err-surface-2"
    comment_id = "memory-comment-#{issue_id}"
    error_msg = "Rate limit exceeded"

    pid = start_orchestrator(Module.concat(__MODULE__, :ErrSurface2))
    initial_state = :sys.get_state(pid)
    entry = running_entry(issue_id, comment_id)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:workpads, %{issue_id => comment_id})
    end)

    # First update: turn_failed stores last_error_reason
    send(pid, {:agent_worker_update, issue_id, turn_failed_update(error_msg)})
    assert_receive {:memory_tracker_comment_update, ^comment_id, body1}, 1_000
    assert body1 =~ "### Error"
    assert body1 =~ error_msg

    # Second update: turn_completed — error reason must still appear in the body
    turn_ok = %{event: :turn_completed, timestamp: DateTime.utc_now()}
    send(pid, {:agent_worker_update, issue_id, turn_ok})
    assert_receive {:memory_tracker_comment_update, ^comment_id, body2}, 1_000

    assert body2 =~ "### Error",
           "Error section must persist in workpad after subsequent turn_completed"

    assert body2 =~ error_msg,
           "Error message must persist in workpad body after subsequent turn_completed"
  end

  test "normal turn_completed does not inject ### Error in workpad" do
    issue_id = "issue-err-surface-3"
    comment_id = "memory-comment-#{issue_id}"

    pid = start_orchestrator(Module.concat(__MODULE__, :ErrSurface3))
    initial_state = :sys.get_state(pid)
    entry = running_entry(issue_id, comment_id)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:workpads, %{issue_id => comment_id})
    end)

    turn_ok = %{event: :turn_completed, timestamp: DateTime.utc_now()}
    send(pid, {:agent_worker_update, issue_id, turn_ok})

    assert_receive {:memory_tracker_comment_update, ^comment_id, body}, 1_000
    refute body =~ "### Error", "Expected NO ### Error section for normal turn_completed"
  end
end
