defmodule SymphonyElixir.WorkpadTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workpad

  setup do
    previous = Application.get_env(:symphony_elixir, :workpad_enabled)
    Application.put_env(:symphony_elixir, :workpad_enabled, true)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:symphony_elixir, :workpad_enabled)
        value -> Application.put_env(:symphony_elixir, :workpad_enabled, value)
      end

      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    :ok
  end

  defp running_entry(overrides \\ %{}) do
    base = %{
      identifier: "MT-WP",
      issue: %Issue{
        id: "issue-wp",
        identifier: "MT-WP",
        title: "Workpad",
        state: "In Development",
        url: "https://example.org/issues/MT-WP"
      },
      session_id: nil,
      turn_count: 1,
      retry_attempt: 0,
      worker_host: "local",
      workspace_path: "/tmp/ws",
      last_agent_event: nil,
      last_agent_text: nil,
      last_agent_message: nil,
      last_agent_timestamp: nil,
      agent_input_tokens: 10,
      agent_output_tokens: 20,
      agent_total_tokens: 30,
      workpad_comment_id: nil
    }

    Map.merge(base, overrides)
  end

  test "extracts agent text from item/agent_message notification payload" do
    update = %{
      event: :notification,
      payload: %{
        "method" => "item/agent_message",
        "params" => %{"text" => "hello from agent"}
      },
      timestamp: DateTime.utc_now()
    }

    updated = Workpad.maybe_sync(running_entry(), update, self())
    assert updated.last_agent_text == "hello from agent"
    refute_received {:memory_tracker_comment, _, _}
  end

  test "schedules a sync on session_started and replies with comment id" do
    update = %{
      event: :session_started,
      session_id: "thread-1-turn-1",
      timestamp: DateTime.utc_now()
    }

    Workpad.maybe_sync(running_entry(%{last_agent_text: "kicking off"}), update, self())

    assert_receive {:memory_tracker_comment, "issue-wp", body}, 1_000
    assert body =~ "## Symphony Workpad"
    assert body =~ "MT-WP"
    assert body =~ "kicking off"

    assert_receive {:workpad_comment_created, "issue-wp", "memory-comment-issue-wp"}, 1_000
  end

  test "updates an existing workpad comment on subsequent turn boundaries" do
    update = %{event: :turn_completed, timestamp: DateTime.utc_now()}

    Workpad.maybe_sync(
      running_entry(%{
        workpad_comment_id: "memory-comment-issue-wp",
        last_agent_text: "second turn"
      }),
      update,
      self()
    )

    assert_receive {:memory_tracker_comment_update, "memory-comment-issue-wp", body}, 1_000
    assert body =~ "second turn"
    refute_received {:memory_tracker_comment, _, _}
  end

  test "does not sync for non-trigger events but still tracks agent text" do
    update = %{
      event: :tool_call_completed,
      payload: %{
        "method" => "item/agent_message",
        "params" => %{"item" => %{"text" => "thinking…"}}
      },
      timestamp: DateTime.utc_now()
    }

    updated = Workpad.maybe_sync(running_entry(), update, self())
    assert updated.last_agent_text == "thinking…"
    refute_received {:memory_tracker_comment, _, _}
    refute_received {:memory_tracker_comment_update, _, _}
  end

  test "no-op when workpad_enabled is false" do
    Application.put_env(:symphony_elixir, :workpad_enabled, false)
    update = %{event: :session_started, timestamp: DateTime.utc_now()}

    Workpad.maybe_sync(running_entry(), update, self())
    refute_receive {:memory_tracker_comment, _, _}, 200
  end

  test "ignores running entries without an issue id" do
    update = %{event: :session_started, timestamp: DateTime.utc_now()}

    entry = running_entry() |> Map.put(:issue, %{})
    Workpad.maybe_sync(entry, update, self())
    refute_receive {:memory_tracker_comment, _, _}, 200
  end

  test "marks running entry as creating and skips a second create while the first is in flight" do
    update_a = %{event: :session_started, timestamp: DateTime.utc_now()}
    update_b = %{event: :turn_completed, timestamp: DateTime.utc_now()}

    entry = running_entry(%{last_agent_text: "first event"})
    entry = Workpad.maybe_sync(entry, update_a, self())

    assert entry.workpad_creating == true
    assert entry.workpad_comment_id == nil

    entry = Workpad.maybe_sync(entry, update_b, self())

    assert entry.workpad_creating == true
    assert entry.workpad_comment_id == nil

    assert_receive {:memory_tracker_comment, "issue-wp", _}, 1_000
    refute_receive {:memory_tracker_comment, _, _}, 200

    assert_receive {:workpad_comment_created, "issue-wp", "memory-comment-issue-wp"}, 1_000
  end

  test "uses update_comment once workpad_comment_id is known and clears the creating flag" do
    update = %{event: :turn_completed, timestamp: DateTime.utc_now()}

    entry =
      running_entry(%{
        workpad_comment_id: "memory-comment-issue-wp",
        workpad_creating: true,
        last_agent_text: "with comment id"
      })

    Workpad.maybe_sync(entry, update, self())

    assert_receive {:memory_tracker_comment_update, "memory-comment-issue-wp", _}, 1_000
    refute_receive {:memory_tracker_comment, _, _}, 200
  end

  test "schedules an update on :agent_terminated so the workpad reflects agent exit without PR" do
    update = %{event: :agent_terminated, timestamp: DateTime.utc_now()}

    entry =
      running_entry(%{
        workpad_comment_id: "memory-comment-issue-wp",
        last_agent_event: :agent_terminated,
        last_agent_text: "Blocked. Wrong repo. Re-dispatch to fe-next-app."
      })

    Workpad.maybe_sync(entry, update, self())

    assert_receive {:memory_tracker_comment_update, "memory-comment-issue-wp", body}, 1_000
    assert body =~ "**Last event**: agent_terminated"
    assert body =~ "Blocked. Wrong repo."
    refute_received {:memory_tracker_comment, _, _}
  end

  test "schedules an update on :pr_attached so the workpad reflects PR shipping" do
    update = %{event: :pr_attached, timestamp: DateTime.utc_now()}

    entry =
      running_entry(%{
        workpad_comment_id: "memory-comment-issue-wp",
        last_agent_event: :pr_attached,
        last_agent_text: "ready for review"
      })

    Workpad.maybe_sync(entry, update, self())

    assert_receive {:memory_tracker_comment_update, "memory-comment-issue-wp", body}, 1_000
    assert body =~ "**Last event**: pr_attached"
    assert body =~ "ready for review"
    refute_received {:memory_tracker_comment, _, _}
  end

  test "extracts text from content blocks list" do
    update = %{
      event: :notification,
      payload: %{
        "method" => "item/agent_message",
        "params" => %{
          "item" => %{
            "content" => [
              %{"type" => "text", "text" => "first"},
              %{"type" => "text", "text" => "second"}
            ]
          }
        }
      },
      timestamp: DateTime.utc_now()
    }

    updated = Workpad.maybe_sync(running_entry(), update, self())
    assert updated.last_agent_text == "first\nsecond"
  end
end
