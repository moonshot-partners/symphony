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
    assert body =~ "PR aberto"
    refute body =~ "**Last event**: pr_attached"
    assert body =~ "PR enviado para revisão"
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

    test "status line maps :pr_attached to friendly text" do
      update = %{event: :pr_attached, timestamp: DateTime.utc_now()}
      Workpad.maybe_sync(pr_running_entry("https://github.com/schoolsoutapp/fe-next-app/pull/511"), update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "PR aberto"
      refute body =~ "Last event**: pr_attached"
    end

    test "status line maps turn_completed to 'Trabalhando'" do
      update = %{event: :turn_completed, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :turn_completed,
          last_agent_text: "doing things"
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "Trabalhando"
    end

    test "status line maps session_started to 'Iniciando'" do
      update = %{event: :session_started, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          last_agent_event: :session_started,
          last_agent_text: "warming up"
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment, _, body}, 1_000
      assert body =~ "Iniciando"
    end

    test "status line maps turn_input_required to 'Aguarda resposta humana'" do
      update = %{event: :turn_input_required, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :turn_input_required,
          last_agent_text: "need input"
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "Aguarda resposta humana"
    end

    test "status line maps turn_failed to 'Falhou'" do
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
      assert body =~ "Falhou"
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

    test "status line maps approval_required to friendly text" do
      update = %{event: :approval_required, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :approval_required,
          last_agent_text: "need approval"
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "Aguarda aprovação"
    end

    test "status line maps turn_ended_with_error to 'Erro'" do
      update = %{event: :turn_ended_with_error, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :turn_ended_with_error,
          last_agent_text: "ended bad"
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "Erro"
    end

    test "status line maps turn_cancelled to 'Cancelado'" do
      update = %{event: :turn_cancelled, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :turn_cancelled,
          last_agent_text: "stop"
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "Cancelado"
    end

    test "details block wraps technical metadata" do
      update = %{event: :pr_attached, timestamp: DateTime.utc_now()}
      Workpad.maybe_sync(pr_running_entry("https://github.com/x/y/pull/1"), update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "<details>"
      assert body =~ "<summary>Detalhes técnicos</summary>"
      assert body =~ "</details>"
    end

    test "workspace path renders only inside details block" do
      update = %{event: :pr_attached, timestamp: DateTime.utc_now()}
      Workpad.maybe_sync(pr_running_entry("https://github.com/x/y/pull/1"), update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      [main, _details] = String.split(body, "<details>", parts: 2)
      refute main =~ "/home/ubuntu/code/ws"
    end

    test "no ISO timestamp in primary view above details block" do
      update = %{event: :pr_attached, timestamp: DateTime.utc_now()}
      Workpad.maybe_sync(pr_running_entry("https://github.com/x/y/pull/1"), update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      [main, _details] = String.split(body, "<details>", parts: 2)
      refute main =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
    end

    test "header literal '## Symphony Workpad' persists (regression)" do
      update = %{event: :pr_attached, timestamp: DateTime.utc_now()}
      Workpad.maybe_sync(pr_running_entry("https://github.com/x/y/pull/1"), update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000

      assert String.starts_with?(body, "## Symphony Workpad") or
               String.starts_with?(body, "\n## Symphony Workpad")
    end
  end

  describe "Sprint 2: closing message + tokens=0 polish" do
    test "pr_attached body shows closing message and hides last_agent_text" do
      update = %{event: :pr_attached, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          last_agent_event: :pr_attached,
          last_agent_text: "thinking about implementation..."
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "PR enviado para revisão"
      refute body =~ "thinking about implementation"
    end

    test "turn_completed keeps showing last_agent_text (not closing message)" do
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
      refute body =~ "PR enviado para revisão"
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
      refute body =~ "PR enviado para revisão"
    end

    test "tokens row renders em-dash when input/output/total are all zero" do
      update = %{event: :turn_completed, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          agent_input_tokens: 0,
          agent_output_tokens: 0,
          agent_total_tokens: 0
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "| Tokens | — |"
      refute body =~ "in=0"
    end

    test "tokens row renders normal counts when any token is non-zero" do
      update = %{event: :turn_completed, timestamp: DateTime.utc_now()}

      entry =
        running_entry(%{
          workpad_comment_id: "memory-comment-issue-wp",
          agent_input_tokens: 55,
          agent_output_tokens: 0,
          agent_total_tokens: 55
        })

      Workpad.maybe_sync(entry, update, self())

      assert_receive {:memory_tracker_comment_update, _, body}, 1_000
      assert body =~ "in=55"
      assert body =~ "total=55"
      refute body =~ "| Tokens | — |"
    end
  end
end
