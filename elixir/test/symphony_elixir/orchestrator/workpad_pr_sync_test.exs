defmodule SymphonyElixir.Orchestrator.WorkpadPrSyncTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.{State, WorkpadPrSync}

  setup do
    previous_workpad_enabled = Application.get_env(:symphony_elixir, :workpad_enabled)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    Application.put_env(:symphony_elixir, :workpad_enabled, true)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    # Completion side effects publish to the cockpit stores; redirect them to a
    # tmp dir so tests never touch /opt/symphony.
    cockpit_store = Path.join(System.tmp_dir!(), "wp-cockpit-#{System.unique_integer([:positive])}")
    System.put_env("SYMPHONY_COCKPIT_EVIDENCE_DIR", Path.join(cockpit_store, "evidence"))
    System.put_env("SYMPHONY_COCKPIT_SUMMARY_DIR", Path.join(cockpit_store, "summaries"))

    # Default required-checks injection so existing tests (and new ones that
    # don't care about CI routing) don't shell out to `gh pr view`.
    Application.put_env(:symphony_elixir, :pr_required_checks_status_fn, fn _issue -> :all_green end)
    Application.put_env(:symphony_elixir, :pr_body_fn, fn _issue -> "" end)
    Application.put_env(:symphony_elixir, :pr_changed_files_fn, fn _issue -> [] end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Progress"],
      tracker_terminal_states: ["Closed", "Done", "Cancelled"],
      qa_evidence_subpath: "fe-next-app/qa-evidence"
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

      Application.delete_env(:symphony_elixir, :pr_required_checks_status_fn)
      Application.delete_env(:symphony_elixir, :pr_body_fn)
      Application.delete_env(:symphony_elixir, :pr_changed_files_fn)
      System.delete_env("SYMPHONY_COCKPIT_EVIDENCE_DIR")
      System.delete_env("SYMPHONY_COCKPIT_SUMMARY_DIR")
      File.rm_rf(cockpit_store)
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
    assert body =~ "PR opened"
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
    assert body =~ "PR opened"
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

  test "routes state to on_reject_state when QA is BLOCKED" do
    issue_id = "issue-qa-blocked-1"

    running = %{
      issue_id => %{
        issue: %Issue{id: issue_id, identifier: "WP-QA-1", state: "Scheduled", repos: []},
        identifier: "WP-QA-1",
        workpad_comment_id: "wp-comment-qa-blocked",
        workspace_path: "/tmp/nonexistent"
      }
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Progress"],
      tracker_terminal_states: ["Closed", "Done", "Cancelled"],
      tracker_on_complete_state: "In Code Review",
      tracker_on_reject_state: "On Hold / Blocked",
      qa_evidence_subpath: "fe-next-app/qa-evidence"
    )

    Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> true end)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn) end)

    state = build_state(running)
    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    assert_receive {:memory_tracker_state_update, ^issue_id, "On Hold / Blocked"}, 1_000
  end

  test "bypasses qa_blocked routing and routes to on_complete_state when pr_engagements has count >= 1 for the issue's PR url" do
    issue_id = "issue-bypass-1"
    pr_url = "https://github.com/org/repo/pull/77"

    running = %{
      issue_id => %{
        issue: %Issue{
          id: issue_id,
          identifier: "WP-BYPASS-1",
          state: "Scheduled",
          repos: [%{name: "fe-next-app", pr: %{url: pr_url}}]
        },
        identifier: "WP-BYPASS-1",
        workpad_comment_id: "wp-comment-bypass-1",
        workspace_path: "/tmp/nonexistent"
      }
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Progress"],
      tracker_terminal_states: ["Closed", "Done", "Cancelled"],
      tracker_on_complete_state: "In Code Review",
      tracker_on_reject_state: "On Hold / Blocked",
      qa_evidence_subpath: "fe-next-app/qa-evidence"
    )

    # PR self-reports BLOCKED; without the bypass marker the issue would
    # be parked in `On Hold / Blocked` and the auto re-engagement loop
    # would terminate after 8s (see state/SYM-16-baseline.md for the
    # empirical observation that motivated this branch).
    Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> true end)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn) end)

    state = %State{
      running: running,
      claimed: MapSet.new([issue_id]),
      workpads: %{},
      retry_attempts: %{},
      pr_engagements: %{pr_url => %{count: 1, cap_hit_shas: MapSet.new()}},
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    # Bypass kicks in → on_complete_state, NOT on_reject_state.
    assert_receive {:memory_tracker_state_update, ^issue_id, "In Code Review"}, 1_000
    refute_receive {:memory_tracker_state_update, ^issue_id, "On Hold / Blocked"}, 100
  end

  test "does NOT bypass when pr_engagements entry has count == 0 (engagement initialized but not yet dispatched)" do
    issue_id = "issue-bypass-zero"
    pr_url = "https://github.com/org/repo/pull/78"

    running = %{
      issue_id => %{
        issue: %Issue{
          id: issue_id,
          identifier: "WP-BZERO",
          state: "Scheduled",
          repos: [%{name: "fe-next-app", pr: %{url: pr_url}}]
        },
        identifier: "WP-BZERO",
        workpad_comment_id: "wp-bypass-zero",
        workspace_path: "/tmp/nonexistent"
      }
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Progress"],
      tracker_terminal_states: ["Closed", "Done", "Cancelled"],
      tracker_on_complete_state: "In Code Review",
      tracker_on_reject_state: "On Hold / Blocked",
      qa_evidence_subpath: "fe-next-app/qa-evidence"
    )

    Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> true end)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn) end)

    state = %State{
      running: running,
      claimed: MapSet.new([issue_id]),
      workpads: %{},
      retry_attempts: %{},
      pr_engagements: %{pr_url => %{count: 0, cap_hit_shas: MapSet.new()}},
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    # count == 0 → bypass NOT armed → QA-BLOCKED routing wins → reject state.
    assert_receive {:memory_tracker_state_update, ^issue_id, "On Hold / Blocked"}, 1_000
    refute_receive {:memory_tracker_state_update, ^issue_id, "In Code Review"}, 100
  end

  test "does NOT bypass when pr_engagements references a different PR url than the issue's repos carry" do
    issue_id = "issue-bypass-mismatch"
    issue_pr_url = "https://github.com/org/repo/pull/79"
    engagement_pr_url = "https://github.com/org/repo/pull/999"

    running = %{
      issue_id => %{
        issue: %Issue{
          id: issue_id,
          identifier: "WP-MISMATCH",
          state: "Scheduled",
          repos: [%{name: "fe-next-app", pr: nil}, %{name: "schools-out", pr: %{url: issue_pr_url}}]
        },
        identifier: "WP-MISMATCH",
        workpad_comment_id: "wp-mismatch",
        workspace_path: "/tmp/nonexistent"
      }
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Progress"],
      tracker_terminal_states: ["Closed", "Done", "Cancelled"],
      tracker_on_complete_state: "In Code Review",
      tracker_on_reject_state: "On Hold / Blocked",
      qa_evidence_subpath: "fe-next-app/qa-evidence"
    )

    Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> true end)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn) end)

    # First repos entry has `pr: nil` (covers pr_urls flat_map fallback).
    # pr_engagements indexes a different url than the issue's actual PR → no
    # bypass match → qa_blocked routes to reject.
    state = %State{
      running: running,
      claimed: MapSet.new([issue_id]),
      workpads: %{},
      retry_attempts: %{},
      pr_engagements: %{engagement_pr_url => %{count: 1, cap_hit_shas: MapSet.new()}},
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    assert_receive {:memory_tracker_state_update, ^issue_id, "On Hold / Blocked"}, 1_000
  end

  test "routes state to on_reject_state when required CI checks are RED" do
    issue_id = "issue-ci-red-1"
    pr_url = "https://github.com/org/repo/pull/200"

    running = %{
      issue_id => %{
        issue: %Issue{
          id: issue_id,
          identifier: "WP-CI-RED-1",
          state: "Scheduled",
          repos: [%{name: "fe-next-app", pr: %{url: pr_url}}]
        },
        identifier: "WP-CI-RED-1",
        workpad_comment_id: "wp-comment-ci-red",
        workspace_path: "/tmp/nonexistent"
      }
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Progress"],
      tracker_terminal_states: ["Closed", "Done", "Cancelled"],
      tracker_on_complete_state: "In Code Review",
      tracker_on_reject_state: "On Hold / Blocked",
      qa_evidence_subpath: "fe-next-app/qa-evidence"
    )

    Application.put_env(:symphony_elixir, :pr_required_checks_status_fn, fn _issue ->
      {:red, ["qa-evidence", "lint"]}
    end)

    Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> false end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :pr_required_checks_status_fn)
      Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn)
    end)

    state = build_state(running)
    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    assert_receive {:memory_tracker_state_update, ^issue_id, "On Hold / Blocked"}, 1_000
    refute_receive {:memory_tracker_state_update, ^issue_id, "In Code Review"}, 100
    # The "why" (## Blocked by CI + failing checks) now goes to the cockpit run
    # summary store, not the tracker thread; its content is unit-tested in
    # CompletionSummaryTest.
  end

  test "does NOT transition when required CI checks are PENDING (retry loop polls)" do
    issue_id = "issue-ci-pending-1"
    pr_url = "https://github.com/org/repo/pull/201"

    running = %{
      issue_id => %{
        issue: %Issue{
          id: issue_id,
          identifier: "WP-CI-PENDING-1",
          state: "Scheduled",
          repos: [%{name: "fe-next-app", pr: %{url: pr_url}}]
        },
        identifier: "WP-CI-PENDING-1",
        workpad_comment_id: "wp-comment-ci-pending",
        workspace_path: "/tmp/nonexistent"
      }
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Progress"],
      tracker_terminal_states: ["Closed", "Done", "Cancelled"],
      tracker_on_complete_state: "In Code Review",
      tracker_on_reject_state: "On Hold / Blocked",
      qa_evidence_subpath: "fe-next-app/qa-evidence"
    )

    Application.put_env(:symphony_elixir, :pr_required_checks_status_fn, fn _issue -> :pending end)
    Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> false end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :pr_required_checks_status_fn)
      Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn)
    end)

    state = build_state(running)
    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    # NO state transition fires (neither complete nor reject) — caller's
    # retry loop re-evaluates on the next reconcile tick.
    refute_receive {:memory_tracker_state_update, ^issue_id, _}, 200
  end

  test "SYM-16 auto-engagement bypass overrides ci_red (lets bounded re-engagement run)" do
    issue_id = "issue-sym16-vs-cired"
    pr_url = "https://github.com/org/repo/pull/202"

    running = %{
      issue_id => %{
        issue: %Issue{
          id: issue_id,
          identifier: "WP-SYM16",
          state: "Scheduled",
          repos: [%{name: "fe-next-app", pr: %{url: pr_url}}]
        },
        identifier: "WP-SYM16",
        workpad_comment_id: "wp-comment-sym16",
        workspace_path: "/tmp/nonexistent"
      }
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Progress"],
      tracker_terminal_states: ["Closed", "Done", "Cancelled"],
      tracker_on_complete_state: "In Code Review",
      tracker_on_reject_state: "On Hold / Blocked",
      qa_evidence_subpath: "fe-next-app/qa-evidence"
    )

    # Even with red CI, the SYM-16 bypass wins so the bounded re-engagement
    # has a chance to land instead of double-routing on every red check.
    Application.put_env(:symphony_elixir, :pr_required_checks_status_fn, fn _ ->
      {:red, ["qa-evidence"]}
    end)

    Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _ -> true end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :pr_required_checks_status_fn)
      Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn)
    end)

    state = %State{
      running: running,
      claimed: MapSet.new([issue_id]),
      workpads: %{},
      retry_attempts: %{},
      pr_engagements: %{pr_url => %{count: 1, cap_hit_shas: MapSet.new()}},
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    assert_receive {:memory_tracker_state_update, ^issue_id, "In Code Review"}, 1_000
    refute_receive {:memory_tracker_state_update, ^issue_id, "On Hold / Blocked"}, 100
  end

  test "routes state to on_reject_state when GateDValidator returns substance fail (SYM-28)" do
    issue_id = "issue-gated-substance-fail"

    running = %{
      issue_id => %{
        issue: %Issue{id: issue_id, identifier: "WP-GATED-FAIL", state: "Scheduled", repos: []},
        identifier: "WP-GATED-FAIL",
        workpad_comment_id: "wp-comment-gated-fail",
        workspace_path: "/tmp/nonexistent",
        pinned_evidence_text: %{
          "AC Evidence" => "## AC Evidence\n\n- AC 1: verified\n- AC 2: verified"
        }
      }
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Progress"],
      tracker_terminal_states: ["Closed", "Done", "Cancelled"],
      tracker_on_complete_state: "In Code Review",
      tracker_on_reject_state: "On Hold / Blocked",
      qa_evidence_subpath: "fe-next-app/qa-evidence"
    )

    Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> false end)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn) end)

    state = build_state(running)
    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    assert_receive {:memory_tracker_state_update, ^issue_id, "On Hold / Blocked"}, 1_000
    refute_receive {:memory_tracker_state_update, ^issue_id, "In Code Review"}, 100
    # Summary (## Blocked by AC evidence) is stored in the cockpit, unit-tested
    # in CompletionSummaryTest.
  end

  test "routes state to on_complete_state when GateDValidator passes (every verified claim has a resolvable ref)" do
    issue_id = "issue-gated-substance-ok"

    base = Path.join(System.tmp_dir!(), "gated-ok-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    file_path = Path.join(base, "lib/foo.ex")
    File.mkdir_p!(Path.dirname(file_path))
    File.write!(file_path, "defmodule Foo do\nend\n")
    on_exit(fn -> File.rm_rf!(base) end)

    running = %{
      issue_id => %{
        issue: %Issue{id: issue_id, identifier: "WP-GATED-OK", state: "Scheduled", repos: []},
        identifier: "WP-GATED-OK",
        workpad_comment_id: "wp-comment-gated-ok",
        workspace_path: base,
        pinned_evidence_text: %{
          "AC Evidence" => "## AC Evidence\n\n- AC 1: verified — lib/foo.ex:10"
        }
      }
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Progress"],
      tracker_terminal_states: ["Closed", "Done", "Cancelled"],
      tracker_on_complete_state: "In Code Review",
      tracker_on_reject_state: "On Hold / Blocked",
      qa_evidence_subpath: "fe-next-app/qa-evidence"
    )

    Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> false end)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn) end)

    state = build_state(running)
    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    assert_receive {:memory_tracker_state_update, ^issue_id, "In Code Review"}, 1_000
    # Ready-for-review summary is stored in the cockpit, unit-tested in
    # CompletionSummaryTest.
  end

  test "routes state to on_reject_state when ConflictDisclosure detects undisclosed extras (SYM-30)" do
    issue_id = "issue-conflict-undisclosed"
    pr_url = "https://github.com/o/r/pull/930"

    description = """
    ## Files (allowed)

    - `app/models/user.rb`
    - `spec/models/user_spec.rb`
    """

    running = %{
      issue_id => %{
        issue: %Issue{
          id: issue_id,
          identifier: "WP-930",
          state: "Scheduled",
          description: description,
          repos: [%{name: "schools-out", pr: %{url: pr_url}}]
        },
        identifier: "WP-930",
        workpad_comment_id: "wp-comment-conflict",
        workspace_path: "/tmp/nonexistent"
      }
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Progress"],
      tracker_terminal_states: ["Closed", "Done", "Cancelled"],
      tracker_on_complete_state: "In Code Review",
      tracker_on_reject_state: "On Hold / Blocked",
      qa_evidence_subpath: "fe-next-app/qa-evidence"
    )

    Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> false end)

    Application.put_env(:symphony_elixir, :pr_changed_files_fn, fn _issue ->
      ["app/models/user.rb", "app/controllers/users_controller.rb", "config/routes.rb"]
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn)
      Application.delete_env(:symphony_elixir, :pr_changed_files_fn)
    end)

    state = build_state(running)
    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    assert_receive {:memory_tracker_state_update, ^issue_id, "On Hold / Blocked"}, 1_000
    refute_receive {:memory_tracker_state_update, ^issue_id, "In Code Review"}, 100
    # Summary (## Blocked by scope disclosure + undisclosed files) is stored in
    # the cockpit, unit-tested in CompletionSummaryTest.
  end

  test "routes state to on_complete_state when extras are disclosed in understanding.md root cause (SYM-30)" do
    issue_id = "issue-conflict-disclosed"
    pr_url = "https://github.com/o/r/pull/931"

    base = Path.join(System.tmp_dir!(), "conflict-disclosed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([base, "state", "wp-931"]))

    File.write!(Path.join([base, "state", "wp-931", "understanding.md"]), """
    ## Plan

    - `app/models/user.rb`

    ## Root cause

    Also touched app/controllers/users_controller.rb to extract a concern
    that had grown past 600 lines.
    """)

    on_exit(fn -> File.rm_rf!(base) end)

    description = """
    ## Files (allowed)

    - `app/models/user.rb`
    """

    running = %{
      issue_id => %{
        issue: %Issue{
          id: issue_id,
          identifier: "WP-931",
          state: "Scheduled",
          description: description,
          repos: [%{name: "schools-out", pr: %{url: pr_url}}]
        },
        identifier: "WP-931",
        workpad_comment_id: "wp-comment-disclosed",
        workspace_path: base
      }
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Progress"],
      tracker_terminal_states: ["Closed", "Done", "Cancelled"],
      tracker_on_complete_state: "In Code Review",
      tracker_on_reject_state: "On Hold / Blocked",
      qa_evidence_subpath: "fe-next-app/qa-evidence"
    )

    Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> false end)

    Application.put_env(:symphony_elixir, :pr_changed_files_fn, fn _issue ->
      ["app/models/user.rb", "app/controllers/users_controller.rb"]
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn)
      Application.delete_env(:symphony_elixir, :pr_changed_files_fn)
    end)

    state = build_state(running)
    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    assert_receive {:memory_tracker_state_update, ^issue_id, "In Code Review"}, 1_000
    refute_receive {:memory_tracker_state_update, ^issue_id, "On Hold / Blocked"}, 100
  end

  test "routes state to on_reject_state when PR body claims PASS but no QA artifact exists (SYM-34)" do
    issue_id = "issue-qa-artifact-missing"
    pr_url = "https://github.com/o/r/pull/892"

    running = %{
      issue_id => %{
        issue: %Issue{
          id: issue_id,
          identifier: "WP-892",
          state: "Scheduled",
          repos: [%{name: "fe-next-app", pr: %{url: pr_url}}]
        },
        identifier: "WP-892",
        workpad_comment_id: "wp-comment-qa-missing",
        workspace_path: "/tmp/nonexistent-892"
      }
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Progress"],
      tracker_terminal_states: ["Closed", "Done", "Cancelled"],
      tracker_on_complete_state: "In Code Review",
      tracker_on_reject_state: "On Hold / Blocked",
      qa_evidence_subpath: "fe-next-app/qa-evidence"
    )

    Application.put_env(:symphony_elixir, :pr_body_fn, fn _issue ->
      "## QA self-review\n\n- Result: PASS\n"
    end)

    Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> false end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :pr_body_fn)
      Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn)
    end)

    state = build_state(running)
    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    assert_receive {:memory_tracker_state_update, ^issue_id, "On Hold / Blocked"}, 1_000
    refute_receive {:memory_tracker_state_update, ^issue_id, "In Code Review"}, 100
    # Summary (## Blocked by missing visual QA evidence) is stored in the
    # cockpit, unit-tested in CompletionSummaryTest.
  end

  test "routes state to on_complete_state when PR claims PASS and qa-evidence artifact is present (SYM-34)" do
    issue_id = "issue-qa-artifact-present"
    pr_url = "https://github.com/o/r/pull/8920"

    base = Path.join(System.tmp_dir!(), "qa-artifact-present-#{System.unique_integer([:positive])}")
    evidence_dir = Path.join(base, "fe-next-app/qa-evidence")
    File.mkdir_p!(evidence_dir)
    File.write!(Path.join(evidence_dir, "shot.png"), "fakepngbytes")

    on_exit(fn -> File.rm_rf!(base) end)

    running = %{
      issue_id => %{
        issue: %Issue{
          id: issue_id,
          identifier: "WP-8920",
          state: "Scheduled",
          repos: [%{name: "fe-next-app", pr: %{url: pr_url}}]
        },
        identifier: "WP-8920",
        workpad_comment_id: "wp-comment-qa-present",
        workspace_path: base
      }
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Progress"],
      tracker_terminal_states: ["Closed", "Done", "Cancelled"],
      tracker_on_complete_state: "In Code Review",
      tracker_on_reject_state: "On Hold / Blocked",
      qa_evidence_subpath: "fe-next-app/qa-evidence"
    )

    Application.put_env(:symphony_elixir, :pr_body_fn, fn _issue ->
      "## QA self-review\n\n- Result: PASS\n"
    end)

    Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> false end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :pr_body_fn)
      Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn)
    end)

    state = build_state(running)
    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    assert_receive {:memory_tracker_state_update, ^issue_id, "In Code Review"}, 1_000
    refute_receive {:memory_tracker_state_update, ^issue_id, "On Hold / Blocked"}, 100
  end

  test "SYM-16 auto-engagement bypass overrides gate_d_substance_fail" do
    issue_id = "issue-sym16-vs-gated"
    pr_url = "https://github.com/org/repo/pull/220"

    running = %{
      issue_id => %{
        issue: %Issue{
          id: issue_id,
          identifier: "WP-SYM16-GATED",
          state: "Scheduled",
          repos: [%{name: "fe-next-app", pr: %{url: pr_url}}]
        },
        identifier: "WP-SYM16-GATED",
        workpad_comment_id: "wp-comment-sym16-gated",
        workspace_path: "/tmp/nonexistent",
        pinned_evidence_text: %{
          "AC Evidence" => "## AC Evidence\n\n- AC 1: verified"
        }
      }
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Progress"],
      tracker_terminal_states: ["Closed", "Done", "Cancelled"],
      tracker_on_complete_state: "In Code Review",
      tracker_on_reject_state: "On Hold / Blocked",
      qa_evidence_subpath: "fe-next-app/qa-evidence"
    )

    state = %State{
      running: running,
      claimed: MapSet.new([issue_id]),
      workpads: %{},
      retry_attempts: %{},
      pr_engagements: %{pr_url => %{count: 1, cap_hit_shas: MapSet.new()}},
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    assert_receive {:memory_tracker_state_update, ^issue_id, "In Code Review"}, 1_000
    refute_receive {:memory_tracker_state_update, ^issue_id, "On Hold / Blocked"}, 100
  end

  test "routes state to on_complete_state when QA is not BLOCKED" do
    issue_id = "issue-qa-ok-1"

    running = %{
      issue_id => %{
        issue: %Issue{id: issue_id, identifier: "WP-QA-2", state: "Scheduled", repos: []},
        identifier: "WP-QA-2",
        workpad_comment_id: "wp-comment-qa-ok",
        workspace_path: "/tmp/nonexistent"
      }
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Progress"],
      tracker_terminal_states: ["Closed", "Done", "Cancelled"],
      tracker_on_complete_state: "In Code Review",
      tracker_on_reject_state: "On Hold / Blocked",
      qa_evidence_subpath: "fe-next-app/qa-evidence"
    )

    Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> false end)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn) end)

    state = build_state(running)
    assert ^state = WorkpadPrSync.sync(state, issue_id, self())

    assert_receive {:memory_tracker_state_update, ^issue_id, "In Code Review"}, 1_000
  end

  describe "DecisionLog emissions" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "workpad_pr_sync_log_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      path = Path.join(tmp, "decisions.jsonl")

      prior_app = Application.get_env(:symphony_elixir, :decision_log_path)
      prior_env = System.get_env("SYMPHONY_DECISION_LOG")
      Application.put_env(:symphony_elixir, :decision_log_path, path)
      System.put_env("SYMPHONY_DECISION_LOG", "1")

      on_exit(fn ->
        File.rm_rf!(tmp)

        case prior_app do
          nil -> Application.delete_env(:symphony_elixir, :decision_log_path)
          val -> Application.put_env(:symphony_elixir, :decision_log_path, val)
        end

        case prior_env do
          nil -> System.delete_env("SYMPHONY_DECISION_LOG")
          val -> System.put_env("SYMPHONY_DECISION_LOG", val)
        end
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Scheduled", "In Progress"],
        tracker_terminal_states: ["Closed", "Done", "Cancelled"],
        tracker_on_complete_state: "In Code Review",
        tracker_on_reject_state: "On Hold / Blocked",
        qa_evidence_subpath: "fe-next-app/qa-evidence"
      )

      {:ok, ledger_path: path}
    end

    defp branches(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["event"] == "workpad_pr_sync.route"))
      |> Enum.map(& &1["payload"]["branch"])
    end

    test "emits default_complete branch when QA is not blocked and no engagement", %{ledger_path: path} do
      issue_id = "i-route-default"
      pr_url = "https://github.com/o/r/pull/100"

      running = %{
        issue_id => %{
          issue: %Issue{
            id: issue_id,
            identifier: "WP-100",
            state: "Scheduled",
            repos: [%{name: "fe-next-app", pr: %{url: pr_url}}]
          },
          identifier: "WP-100",
          workpad_comment_id: "wp-100",
          workspace_path: "/tmp/nonexistent"
        }
      }

      Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> false end)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn) end)

      _ = WorkpadPrSync.sync(build_state(running), issue_id, self())
      assert "default_complete" in branches(path)
    end

    test "emits auto_engagement_bypass branch when PR has active engagement", %{ledger_path: path} do
      issue_id = "i-route-bypass"
      pr_url = "https://github.com/o/r/pull/101"

      running = %{
        issue_id => %{
          issue: %Issue{
            id: issue_id,
            identifier: "WP-101",
            state: "Scheduled",
            repos: [%{name: "fe-next-app", pr: %{url: pr_url}}]
          },
          identifier: "WP-101",
          workpad_comment_id: "wp-101",
          workspace_path: "/tmp/nonexistent"
        }
      }

      Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> true end)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn) end)

      state =
        %{build_state(running) | pr_engagements: %{pr_url => %{count: 1, cap_hit_shas: MapSet.new()}}}

      _ = WorkpadPrSync.sync(state, issue_id, self())
      assert "auto_engagement_bypass" in branches(path)
    end

    test "emits ci_red branch when required checks are RED and no engagement bypass", %{ledger_path: path} do
      issue_id = "i-route-cired"
      pr_url = "https://github.com/o/r/pull/210"

      running = %{
        issue_id => %{
          issue: %Issue{
            id: issue_id,
            identifier: "WP-210",
            state: "Scheduled",
            repos: [%{name: "fe-next-app", pr: %{url: pr_url}}]
          },
          identifier: "WP-210",
          workpad_comment_id: "wp-210",
          workspace_path: "/tmp/nonexistent"
        }
      }

      Application.put_env(:symphony_elixir, :pr_required_checks_status_fn, fn _ ->
        {:red, ["qa-evidence"]}
      end)

      Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _ -> false end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :pr_required_checks_status_fn)
        Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn)
      end)

      _ = WorkpadPrSync.sync(build_state(running), issue_id, self())
      assert "ci_red" in branches(path)
    end

    test "emits ci_pending branch when required checks are PENDING", %{ledger_path: path} do
      issue_id = "i-route-cipending"
      pr_url = "https://github.com/o/r/pull/211"

      running = %{
        issue_id => %{
          issue: %Issue{
            id: issue_id,
            identifier: "WP-211",
            state: "Scheduled",
            repos: [%{name: "fe-next-app", pr: %{url: pr_url}}]
          },
          identifier: "WP-211",
          workpad_comment_id: "wp-211",
          workspace_path: "/tmp/nonexistent"
        }
      }

      Application.put_env(:symphony_elixir, :pr_required_checks_status_fn, fn _ -> :pending end)
      Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _ -> false end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :pr_required_checks_status_fn)
        Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn)
      end)

      _ = WorkpadPrSync.sync(build_state(running), issue_id, self())
      assert "ci_pending" in branches(path)
    end

    test "emits gate_d_substance_fail branch when verified AC lacks resolvable ref", %{ledger_path: path} do
      issue_id = "i-route-gated-fail"

      running = %{
        issue_id => %{
          issue: %Issue{id: issue_id, identifier: "WP-220", state: "Scheduled", repos: []},
          identifier: "WP-220",
          workpad_comment_id: "wp-220",
          workspace_path: "/tmp/nonexistent",
          pinned_evidence_text: %{"AC Evidence" => "## AC Evidence\n\n- AC 1: verified"}
        }
      }

      Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _ -> false end)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn) end)

      _ = WorkpadPrSync.sync(build_state(running), issue_id, self())
      assert "gate_d_substance_fail" in branches(path)
    end

    test "emits conflict_disclosure_fail branch when description allowlist excludes undisclosed diff", %{ledger_path: path} do
      issue_id = "i-route-conflict"
      pr_url = "https://github.com/o/r/pull/930"

      description = """
      ## Files (allowed)

      - `lib/a.ex`
      """

      running = %{
        issue_id => %{
          issue: %Issue{
            id: issue_id,
            identifier: "WP-930-LEDGER",
            state: "Scheduled",
            description: description,
            repos: [%{name: "fe-next-app", pr: %{url: pr_url}}]
          },
          identifier: "WP-930-LEDGER",
          workpad_comment_id: "wp-930",
          workspace_path: "/tmp/nonexistent"
        }
      }

      Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _ -> false end)

      Application.put_env(:symphony_elixir, :pr_changed_files_fn, fn _ ->
        ["lib/a.ex", "lib/b.ex"]
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn)
        Application.delete_env(:symphony_elixir, :pr_changed_files_fn)
      end)

      _ = WorkpadPrSync.sync(build_state(running), issue_id, self())
      assert "conflict_disclosure_fail" in branches(path)
    end

    test "emits qa_blocked branch when QA self-reports BLOCKED and not in engagement", %{ledger_path: path} do
      issue_id = "i-route-qa-blocked"
      pr_url = "https://github.com/o/r/pull/102"

      running = %{
        issue_id => %{
          issue: %Issue{
            id: issue_id,
            identifier: "WP-102",
            state: "Scheduled",
            repos: [%{name: "fe-next-app", pr: %{url: pr_url}}]
          },
          identifier: "WP-102",
          workpad_comment_id: "wp-102",
          workspace_path: "/tmp/nonexistent"
        }
      }

      Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> true end)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn) end)

      _ = WorkpadPrSync.sync(build_state(running), issue_id, self())
      assert "qa_blocked" in branches(path)
    end
  end
end
