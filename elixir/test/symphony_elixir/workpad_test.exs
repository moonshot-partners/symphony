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
    assert body =~ "Starting"
    assert body =~ "kicking off"
    refute body =~ "## Symphony Workpad"
    refute body =~ "**Symphony —"
    refute body =~ "<details>"

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
    assert body =~ "PR opened"
    refute body =~ "Last event"
    refute body =~ "<details>"
    refute body =~ "ready for review"
    refute_received {:memory_tracker_comment, _, _}
  end

  test "heartbeat: non-sync event triggers update when last sync is older than threshold" do
    stale_ts = DateTime.add(DateTime.utc_now(), -60, :second)

    entry =
      running_entry(%{
        workpad_comment_id: "memory-comment-issue-wp",
        last_workpad_sync_at: stale_ts
      })

    update = %{
      event: :notification,
      payload: %{
        "method" => "item/agent_message",
        "params" => %{"text" => "still working"}
      },
      timestamp: DateTime.utc_now()
    }

    updated = Workpad.maybe_sync(entry, update, self())

    assert_receive {:memory_tracker_comment_update, "memory-comment-issue-wp", body}, 1_000
    assert body =~ "still working"
    assert %DateTime{} = updated.last_workpad_sync_at
    assert DateTime.compare(updated.last_workpad_sync_at, stale_ts) == :gt
  end

  test "heartbeat: non-sync event does not trigger update when last sync is recent" do
    fresh_ts = DateTime.add(DateTime.utc_now(), -2, :second)

    entry =
      running_entry(%{
        workpad_comment_id: "memory-comment-issue-wp",
        last_workpad_sync_at: fresh_ts
      })

    update = %{
      event: :notification,
      payload: %{
        "method" => "item/agent_message",
        "params" => %{"text" => "noise"}
      },
      timestamp: DateTime.utc_now()
    }

    Workpad.maybe_sync(entry, update, self())

    refute_receive {:memory_tracker_comment_update, _, _}, 200
    refute_receive {:memory_tracker_comment, _, _}, 200
  end

  test "heartbeat is skipped while workpad_comment_id is still nil" do
    stale_ts = DateTime.add(DateTime.utc_now(), -60, :second)

    entry =
      running_entry(%{
        workpad_comment_id: nil,
        workpad_creating: true,
        last_workpad_sync_at: stale_ts
      })

    update = %{
      event: :notification,
      payload: %{
        "method" => "item/agent_message",
        "params" => %{"text" => "while creating"}
      },
      timestamp: DateTime.utc_now()
    }

    Workpad.maybe_sync(entry, update, self())

    refute_receive {:memory_tracker_comment, _, _}, 200
    refute_receive {:memory_tracker_comment_update, _, _}, 200
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

  test "turn_failed update stores last_error_reason from details[error]" do
    update = %{
      event: :turn_failed,
      details: %{"turn_id" => "turn-abc", "error" => "You've hit your limit · resets May 16, 2am (UTC)"},
      payload: %{"method" => "turn/failed", "params" => %{}},
      raw: "",
      timestamp: DateTime.utc_now()
    }

    updated = Workpad.maybe_sync(running_entry(), update, self())
    assert updated.last_error_reason == "You've hit your limit · resets May 16, 2am (UTC)"
  end

  test "turn_failed sync renders Error section in workpad body" do
    update = %{
      event: :turn_failed,
      details: %{"turn_id" => "turn-abc", "error" => "Rate limit hit"},
      payload: %{"method" => "turn/failed", "params" => %{}},
      raw: "",
      timestamp: DateTime.utc_now()
    }

    entry = running_entry(%{workpad_comment_id: "memory-comment-issue-wp", last_error_reason: "Rate limit hit"})
    Workpad.maybe_sync(entry, update, self())

    assert_receive {:memory_tracker_comment_update, "memory-comment-issue-wp", body}, 1_000
    assert body =~ "### Error"
    assert body =~ "Rate limit hit"
  end

  test "normal turn_completed does not render Error section" do
    update = %{event: :turn_completed, timestamp: DateTime.utc_now()}

    entry = running_entry(%{workpad_comment_id: "memory-comment-issue-wp"})
    Workpad.maybe_sync(entry, update, self())

    assert_receive {:memory_tracker_comment_update, "memory-comment-issue-wp", body}, 1_000
    refute body =~ "### Error"
  end

  describe "Sprint 1: template visual redesign" do
    defp pr_running_entry(pr_url) do
      issue = %Issue{
        id: "issue-wp",
        identifier: "MT-WP",
        title: "Workpad",
        state: "In Development",
        url: "https://example.org/issues/MT-WP",
        repos: [%{name: "schoolsoutapp/fe-next-app", pr: %{url: pr_url}}]
      }

      %{
        identifier: "MT-WP",
        issue: issue,
        session_id: nil,
        turn_count: 2,
        retry_attempt: 0,
        worker_host: "local",
        workspace_path: "/home/ubuntu/code/ws",
        last_agent_event: :pr_attached,
        last_agent_text: "ready for review",
        agent_input_tokens: 55,
        agent_output_tokens: 23_593,
        agent_total_tokens: 23_648,
        workpad_comment_id: "memory-comment-issue-wp"
      }
    end

    test "status line maps :pr_attached to 'PR opened'" do
      update = %{event: :pr_attached, timestamp: DateTime.utc_now()}
      Workpad.maybe_sync(pr_running_entry("https://github.com/schoolsoutapp/fe-next-app/pull/511"), update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "PR opened"
      refute body =~ "Last event"
    end

    test "status line maps turn_completed to 'Working'" do
      update = %{event: :turn_completed, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :turn_completed,
          last_agent_text: "doing things"
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "Working"
    end

    test "status line maps session_started to 'Starting'" do
      update = %{event: :session_started, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          last_agent_event: :session_started,
          last_agent_text: "warming up"
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment, _, body}, 1_000
      assert body =~ "Starting"
    end

    test "status line maps turn_input_required to 'Needs human reply'" do
      update = %{event: :turn_input_required, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :turn_input_required,
          last_agent_text: "need input"
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "Needs human reply"
    end

    test "status line maps turn_failed to 'Failed'" do
      update = %{
        event: :turn_failed,
        details: %{"error" => "boom"},
        timestamp: DateTime.utc_now()
      }

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :turn_failed,
          last_agent_text: "blew up"
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "Failed"
    end

    test "PR url renders as markdown link when issue.repos carries pr.url" do
      update = %{event: :pr_attached, timestamp: DateTime.utc_now()}
      pr_url = "https://github.com/schoolsoutapp/fe-next-app/pull/511"
      Workpad.maybe_sync(pr_running_entry(pr_url), update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "[#511 fe-next-app](#{pr_url})"
    end

    test "PR url line absent when no repo carries a pr" do
      update = %{event: :turn_completed, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :turn_completed
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      refute body =~ ~r/\[#\d+ /
      refute body =~ ~r/\]\(https?:\/\//
    end

    test "PR url with trailing slash falls back to repo-only label" do
      update = %{event: :pr_attached, timestamp: DateTime.utc_now()}
      pr_url = "https://github.com/schoolsoutapp/fe-next-app/pull/511/"
      Workpad.maybe_sync(pr_running_entry(pr_url), update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "[#511 fe-next-app](#{pr_url})"
    end

    test "PR url without /pull/ segment renders repo-only label without empty number" do
      update = %{event: :pr_attached, timestamp: DateTime.utc_now()}
      pr_url = "https://github.com/schoolsoutapp/fe-next-app"
      Workpad.maybe_sync(pr_running_entry(pr_url), update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "[fe-next-app](#{pr_url})"
      refute body =~ "[# "
      refute body =~ "[#]"
    end

    test "status line maps approval_required to 'Needs approval'" do
      update = %{event: :approval_required, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :approval_required,
          last_agent_text: "need approval"
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "Needs approval"
    end

    test "status line maps turn_ended_with_error to 'Failed'" do
      update = %{event: :turn_ended_with_error, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :turn_ended_with_error,
          last_agent_text: "ended bad"
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "Failed"
    end

    test "status line maps turn_cancelled to 'Cancelled'" do
      update = %{event: :turn_cancelled, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :turn_cancelled,
          last_agent_text: "stop"
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "Cancelled"
    end

    test "no <details> collapsible block in body" do
      update = %{event: :pr_attached, timestamp: DateTime.utc_now()}
      Workpad.maybe_sync(pr_running_entry("https://github.com/x/y/pull/1"), update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      refute body =~ "<details>"
      refute body =~ "<summary>"
      refute body =~ "</details>"
    end

    test "workspace path is not rendered" do
      update = %{event: :pr_attached, timestamp: DateTime.utc_now()}
      Workpad.maybe_sync(pr_running_entry("https://github.com/x/y/pull/1"), update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      refute body =~ "/home/ubuntu/code/ws"
    end

    test "no ISO timestamp anywhere in body" do
      update = %{event: :pr_attached, timestamp: DateTime.utc_now()}
      Workpad.maybe_sync(pr_running_entry("https://github.com/x/y/pull/1"), update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      refute body =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
    end

    test "no '## Symphony Workpad' h2 header" do
      update = %{event: :pr_attached, timestamp: DateTime.utc_now()}
      Workpad.maybe_sync(pr_running_entry("https://github.com/x/y/pull/1"), update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      refute body =~ "## Symphony Workpad"
      refute body =~ "**Symphony —"
    end
  end

  describe "Sprint 2: closing message + tokens polish" do
    test "pr_attached body hides last_agent_text (PR description has it)" do
      update = %{event: :pr_attached, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :pr_attached,
          last_agent_text: "thinking about implementation...",
          issue: %Issue{
            id: "issue-wp",
            identifier: "MT-WP",
            repos: [%{name: "schoolsoutapp/fe-next-app", pr: %{url: "https://github.com/schoolsoutapp/fe-next-app/pull/9"}}]
          }
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "PR opened"
      refute body =~ "thinking about implementation"
    end

    test "turn_completed keeps showing last_agent_text" do
      update = %{event: :turn_completed, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :turn_completed,
          last_agent_text: "deep in the middle of work"
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "deep in the middle of work"
      refute body =~ "PR opened"
    end

    test "session_started keeps showing last_agent_text" do
      update = %{event: :session_started, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          last_agent_event: :session_started,
          last_agent_text: "spinning up agent"
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment, "issue-wp", body}, 1_000
      assert body =~ "spinning up agent"
      refute body =~ "PR opened"
    end

    test "tokens render em-dash when input/output/total are all zero" do
      update = %{event: :turn_completed, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :turn_completed,
          agent_input_tokens: 0,
          agent_output_tokens: 0,
          agent_total_tokens: 0
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "—"
      refute body =~ "in=0"
      refute body =~ "0 tok"
    end

    test "tokens render compact 'k' suffix when >= 1000" do
      update = %{event: :turn_completed, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :turn_completed,
          agent_input_tokens: 100,
          agent_output_tokens: 15_400,
          agent_total_tokens: 15_500
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "15.5k tok"
      refute body =~ "in=100"
      refute body =~ "total=15500"
    end

    test "tokens render raw count when < 1000" do
      update = %{event: :turn_completed, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :turn_completed,
          agent_input_tokens: 200,
          agent_output_tokens: 700,
          agent_total_tokens: 900
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "900 tok"
      refute body =~ "0.9k"
    end
  end

  describe "run-ledger outcome line (SYMPHONY_RUN_LEDGER flag)" do
    setup do
      previous = System.get_env("SYMPHONY_RUN_LEDGER")
      System.delete_env("SYMPHONY_RUN_LEDGER")

      on_exit(fn ->
        case previous do
          nil -> System.delete_env("SYMPHONY_RUN_LEDGER")
          value -> System.put_env("SYMPHONY_RUN_LEDGER", value)
        end
      end)

      :ok
    end

    test "pr_attached body folds outcome into header when flag is on" do
      System.put_env("SYMPHONY_RUN_LEDGER", "1")
      update = %{event: :pr_attached, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :pr_attached,
          agent_total_tokens: 4200,
          turn_count: 7,
          retry_attempt: 1,
          issue: %Issue{
            id: "issue-wp",
            identifier: "MT-WP",
            repos: [%{name: "x", pr: %{url: "https://github.com/o/r/pull/9", merged: false, review: nil}}]
          }
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "PR opened"
      assert body =~ "pr_open"
      assert body =~ "4.2k tok"
      assert body =~ "7 turns"
      assert body =~ "1 retries"
      refute body =~ "Run outcome"
    end

    test "pr_attached body omits outcome label when flag is off but still shows tok/turns" do
      update = %{event: :pr_attached, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :pr_attached,
          agent_total_tokens: 4200,
          turn_count: 7,
          retry_attempt: 0,
          issue: %Issue{
            id: "issue-wp",
            identifier: "MT-WP",
            repos: [%{name: "x", pr: %{url: "https://github.com/o/r/pull/9"}}]
          }
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      refute body =~ "Run outcome"
      refute body =~ "pr_open"
      assert body =~ "PR opened"
      assert body =~ "4.2k tok"
      assert body =~ "7 turns"
    end

    test "non-pr_attached events never get the outcome marker even with flag on" do
      System.put_env("SYMPHONY_RUN_LEDGER", "1")
      update = %{event: :turn_completed, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :turn_completed
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      refute body =~ "Run outcome"
      refute body =~ "pr_open"
    end
  end
end
