defmodule SymphonyElixir.Orchestrator.ReconcileTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.{DispatchGate, Reconcile, State}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Scheduled", "In Development"],
      tracker_terminal_states: ["Released / Live", "Closed", "Canceled", "Duplicate"],
      tracker_on_pickup_state: "In Development",
      tracker_on_complete_state: "In QA / Review"
    )

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :pr_ready_fn)
      Application.delete_env(:symphony_elixir, :pr_critical_review_fn)
    end)

    :ok
  end

  defp build_issue(opts \\ []) do
    %Issue{
      id: Keyword.get(opts, :id, "issue-1"),
      identifier: Keyword.get(opts, :identifier, "ISS-1"),
      state: Keyword.get(opts, :state, "In Development"),
      has_pr_attachment: Keyword.get(opts, :has_pr_attachment, false),
      assigned_to_worker: Keyword.get(opts, :assigned_to_worker, true),
      assignee_id: Keyword.get(opts, :assignee_id, "worker-id"),
      repos: Keyword.get(opts, :repos, [])
    }
  end

  defp running_state(issue) do
    %State{
      running: %{
        issue.id => %{
          identifier: issue.identifier,
          issue: issue
        }
      },
      claimed: MapSet.new([issue.id]),
      workpads: %{},
      retry_attempts: %{},
      tick_timer_ref: nil,
      tick_token: nil,
      next_poll_due_at_ms: nil,
      poll_interval_ms: 1,
      max_concurrent_agents: 1
    }
  end

  defp record_terminate(parent) do
    fn state, issue_id, cleanup ->
      send(parent, {:terminate, issue_id, cleanup})
      %{state | running: Map.delete(state.running, issue_id)}
    end
  end

  defp record_pr_sync(parent) do
    fn state, issue_id ->
      send(parent, {:pr_sync, issue_id})
      state
    end
  end

  describe "run/2" do
    test "returns state untouched when running map is empty" do
      state = %State{
        running: %{},
        claimed: MapSet.new(),
        workpads: %{},
        retry_attempts: %{},
        tick_timer_ref: nil,
        tick_token: nil,
        next_poll_due_at_ms: nil,
        poll_interval_ms: 1,
        max_concurrent_agents: 1
      }

      assert ^state =
               Reconcile.run(state, %{
                 terminate_fn: record_terminate(self()),
                 pr_sync_fn: record_pr_sync(self()),
                 fetch_fn: fn _ids -> {:ok, []} end
               })

      refute_receive {:terminate, _, _}, 50
    end

    test "keeps state unchanged when fetch_fn returns {:error, _}" do
      issue = build_issue()
      state = running_state(issue)

      result =
        Reconcile.run(state, %{
          terminate_fn: record_terminate(self()),
          pr_sync_fn: record_pr_sync(self()),
          fetch_fn: fn _ids -> {:error, :boom} end
        })

      assert result == state
      refute_receive {:terminate, _, _}, 50
    end

    test "terminal state -> terminate with cleanup_workspace=true" do
      issue = build_issue(state: "Released / Live")
      state = running_state(issue)

      Reconcile.run(state, %{
        terminate_fn: record_terminate(self()),
        pr_sync_fn: record_pr_sync(self()),
        fetch_fn: fn _ids -> {:ok, [issue]} end
      })

      assert_received {:terminate, "issue-1", true}
    end

    test "ready PR attachment -> pr_sync then terminate with cleanup" do
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url -> true end)

      issue =
        build_issue(
          has_pr_attachment: true,
          repos: [%{name: "r", pr: %{url: "https://github.com/x/y/pull/1"}}]
        )

      state = running_state(issue)

      result =
        Reconcile.run(state, %{
          terminate_fn: record_terminate(self()),
          pr_sync_fn: record_pr_sync(self()),
          fetch_fn: fn _ids -> {:ok, [issue]} end
        })

      assert_received {:pr_sync, "issue-1"}
      assert_received {:terminate, "issue-1", true}
      assert MapSet.member?(result.completed, "issue-1")
    end

    test "ready PR attachment with critical review stays active for rework" do
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url -> true end)

      Application.put_env(:symphony_elixir, :pr_critical_review_fn, fn _issue ->
        {:critical, %{count: 2, items: ["bad field"], head_sha: "abc123"}}
      end)

      issue =
        build_issue(
          has_pr_attachment: true,
          repos: [%{name: "r", pr: %{url: "https://github.com/x/y/pull/1"}}]
        )

      state = running_state(issue)

      result =
        Reconcile.run(state, %{
          terminate_fn: record_terminate(self()),
          pr_sync_fn: record_pr_sync(self()),
          fetch_fn: fn _ids -> {:ok, [issue]} end
        })

      refute_received {:pr_sync, "issue-1"}
      refute_received {:terminate, "issue-1", true}
      assert Map.has_key?(result.running, "issue-1")
      refute MapSet.member?(result.completed, "issue-1")
    end

    test "ready PR attachment with critical review after auto reengagement completes so cap loop can park it" do
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url -> true end)

      fe_pr_url = "https://github.com/schoolsoutapp/fe-next-app/pull/617"
      rails_pr_url = "https://github.com/schoolsoutapp/schools-out/pull/936"

      Application.put_env(:symphony_elixir, :pr_critical_review_fn, fn _issue ->
        {:critical, %{count: 5, items: ["still broken"], head_sha: "sha-2", pr_url: fe_pr_url}}
      end)

      issue =
        build_issue(
          has_pr_attachment: true,
          repos: [
            %{name: "schools-out", pr: %{url: rails_pr_url}},
            %{name: "rollcall", pr: nil},
            %{name: "fe-next-app", pr: %{url: fe_pr_url}}
          ]
        )

      state =
        issue
        |> running_state()
        |> Map.put(:pr_engagements, %{fe_pr_url => %{count: 1, cap_hit_shas: MapSet.new()}})

      result =
        Reconcile.run(state, %{
          terminate_fn: record_terminate(self()),
          pr_sync_fn: record_pr_sync(self()),
          fetch_fn: fn _ids -> {:ok, [issue]} end
        })

      assert_received {:pr_sync, "issue-1"}
      assert_received {:terminate, "issue-1", true}
      refute Map.has_key?(result.running, "issue-1")
      assert MapSet.member?(result.completed, "issue-1")
    end

    test "multi-repo PR attachment stays active until every attached PR is ready" do
      rails_pr_url = "https://github.com/schoolsoutapp/schools-out/pull/936"
      fe_pr_url = "https://github.com/schoolsoutapp/fe-next-app/pull/617"

      Application.put_env(:symphony_elixir, :pr_ready_fn, fn
        ^rails_pr_url -> true
        ^fe_pr_url -> false
      end)

      issue =
        build_issue(
          has_pr_attachment: true,
          repos: [
            %{name: "schools-out", pr: %{url: rails_pr_url}},
            %{name: "fe-next-app", pr: %{url: fe_pr_url}}
          ]
        )

      state = running_state(issue)

      result =
        Reconcile.run(state, %{
          terminate_fn: record_terminate(self()),
          pr_sync_fn: record_pr_sync(self()),
          fetch_fn: fn _ids -> {:ok, [issue]} end
        })

      refute_received {:pr_sync, "issue-1"}
      refute_received {:terminate, "issue-1", true}
      assert Map.has_key?(result.running, "issue-1")
      refute MapSet.member?(result.completed, "issue-1")
    end

    test "ready PR attachment refreshes cached issue before terminate" do
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url -> true end)

      stale_issue = build_issue(has_pr_attachment: false, repos: [])

      fresh_issue =
        build_issue(
          has_pr_attachment: true,
          repos: [%{name: "r", pr: %{url: "https://github.com/x/y/pull/840"}}]
        )

      state = running_state(stale_issue)

      terminate_fn = fn state, issue_id, cleanup ->
        send(self(), {:terminate_issue, Map.fetch!(state.running, issue_id).issue, cleanup})
        %{state | running: Map.delete(state.running, issue_id)}
      end

      Reconcile.run(state, %{
        terminate_fn: terminate_fn,
        pr_sync_fn: record_pr_sync(self()),
        fetch_fn: fn _ids -> {:ok, [fresh_issue]} end
      })

      assert_received {:pr_sync, "issue-1"}
      assert_received {:terminate_issue, terminated_issue, true}
      assert terminated_issue.repos == fresh_issue.repos
      assert terminated_issue.has_pr_attachment == true
    end

    test "stale (not-ready) PR attachment + active state -> keep agent running, refresh issue" do
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url -> false end)

      issue =
        build_issue(
          state: "In Development",
          has_pr_attachment: true,
          repos: [%{name: "r", pr: %{url: "https://github.com/x/y/pull/1"}}]
        )

      state = running_state(issue)

      result =
        Reconcile.run(state, %{
          terminate_fn: record_terminate(self()),
          pr_sync_fn: record_pr_sync(self()),
          fetch_fn: fn _ids -> {:ok, [issue]} end
        })

      refute_received {:terminate, _, _}
      refute_received {:pr_sync, _}
      assert Map.has_key?(result.running, "issue-1")
    end

    test "stale PR attachment + non-active state -> terminate with cleanup" do
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url -> false end)

      issue =
        build_issue(
          state: "Backlog",
          has_pr_attachment: true,
          repos: [%{name: "r", pr: %{url: "https://github.com/x/y/pull/1"}}]
        )

      state = running_state(issue)

      Reconcile.run(state, %{
        terminate_fn: record_terminate(self()),
        pr_sync_fn: record_pr_sync(self()),
        fetch_fn: fn _ids -> {:ok, [issue]} end
      })

      assert_received {:terminate, "issue-1", true}
    end

    test "no longer routed to worker -> terminate with cleanup" do
      issue = build_issue(assigned_to_worker: false, assignee_id: "someone-else")
      state = running_state(issue)

      Reconcile.run(state, %{
        terminate_fn: record_terminate(self()),
        pr_sync_fn: record_pr_sync(self()),
        fetch_fn: fn _ids -> {:ok, [issue]} end
      })

      assert_received {:terminate, "issue-1", true}
    end

    test "active state, routable, no PR -> refresh cached issue payload" do
      issue = build_issue(state: "In Development", title: "first")
      state = running_state(issue)
      refreshed = %{issue | state: "In Development"}

      result =
        Reconcile.run(state, %{
          terminate_fn: record_terminate(self()),
          pr_sync_fn: record_pr_sync(self()),
          fetch_fn: fn _ids -> {:ok, [refreshed]} end
        })

      refute_received {:terminate, _, _}
      assert result.running["issue-1"].issue == refreshed
    end

    test "non-active, non-terminal, no PR -> terminate with cleanup" do
      issue = build_issue(state: "Backlog")
      state = running_state(issue)

      Reconcile.run(state, %{
        terminate_fn: record_terminate(self()),
        pr_sync_fn: record_pr_sync(self()),
        fetch_fn: fn _ids -> {:ok, [issue]} end
      })

      assert_received {:terminate, "issue-1", true}
    end

    test "running issue missing from fetch result -> terminate (without cleanup)" do
      tracked = build_issue(id: "issue-1")
      state = running_state(tracked)

      Reconcile.run(state, %{
        terminate_fn: record_terminate(self()),
        pr_sync_fn: record_pr_sync(self()),
        fetch_fn: fn _ids -> {:ok, []} end
      })

      assert_received {:terminate, "issue-1", false}
    end
  end

  describe "defensive fallback heads" do
    test "non-Issue payload in fetch result is filtered from missing-id reduction (no terminate)" do
      issue = build_issue()
      state = running_state(issue)

      Reconcile.run(state, %{
        terminate_fn: record_terminate(self()),
        pr_sync_fn: record_pr_sync(self()),
        fetch_fn: fn _ids -> {:ok, [issue, %{not_an_issue: true}]} end
      })

      refute_received {:terminate, "issue-1", _}
    end

    test "log_missing_running_issue with running entry lacking :identifier still terminates" do
      issue = build_issue()
      state = running_state(issue)
      state = %{state | running: %{issue.id => %{issue: issue}}}

      Reconcile.run(state, %{
        terminate_fn: record_terminate(self()),
        pr_sync_fn: record_pr_sync(self()),
        fetch_fn: fn _ids -> {:ok, []} end
      })

      assert_received {:terminate, "issue-1", false}
    end

    test "refresh_running_issue_state is a no-op when running map has no entry for issue.id" do
      issue = build_issue(state: "In Development")

      state = %State{
        running: %{},
        claimed: MapSet.new(),
        workpads: %{},
        retry_attempts: %{},
        tick_timer_ref: nil,
        tick_token: nil,
        next_poll_due_at_ms: nil,
        poll_interval_ms: 1,
        max_concurrent_agents: 1
      }

      state_with_phantom = %{state | running: %{"issue-1" => %{identifier: "x"}}}

      result =
        Reconcile.run(state_with_phantom, %{
          terminate_fn: record_terminate(self()),
          pr_sync_fn: record_pr_sync(self()),
          fetch_fn: fn _ids -> {:ok, [issue]} end
        })

      assert result.running["issue-1"] == %{identifier: "x"}
    end
  end

  describe "reconcile_issue_states/4" do
    test "drives same per-issue decision pipeline as run/2 (test shim)" do
      issue = build_issue(state: "Released / Live")
      state = running_state(issue)

      Reconcile.reconcile_issue_states(
        state,
        [issue],
        record_terminate(self()),
        record_pr_sync(self())
      )

      assert_received {:terminate, "issue-1", true}
    end
  end

  describe "active/terminal state set overrides" do
    test "uses caller-provided active/terminal sets when supplied" do
      issue = build_issue(state: "CustomTerminal")
      state = running_state(issue)

      Reconcile.run(state, %{
        terminate_fn: record_terminate(self()),
        pr_sync_fn: record_pr_sync(self()),
        fetch_fn: fn _ids -> {:ok, [issue]} end,
        active_states: MapSet.new(["customactive"]),
        terminal_states: MapSet.new(["customterminal"])
      })

      assert_received {:terminate, "issue-1", true}
    end

    test "defaults pull from DispatchGate when sets not provided" do
      assert MapSet.size(DispatchGate.terminal_state_set()) > 0
      assert MapSet.size(DispatchGate.active_state_set()) > 0
    end
  end

  describe "DecisionLog emissions" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "reconcile_log_#{System.unique_integer([:positive])}")
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

      {:ok, ledger_path: path}
    end

    defp decisions(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
    end

    defp branches(path) do
      path
      |> decisions()
      |> Enum.filter(&(&1["event"] == "reconcile.decision"))
      |> Enum.map(& &1["payload"]["branch"])
    end

    test "emits run + terminal_state branch", %{ledger_path: path} do
      issue = build_issue(state: "Closed")
      state = running_state(issue)

      Reconcile.run(state, %{
        terminate_fn: record_terminate(self()),
        pr_sync_fn: record_pr_sync(self()),
        fetch_fn: fn _ids -> {:ok, [issue]} end
      })

      events = decisions(path) |> Enum.map(& &1["event"])
      assert "reconcile.run" in events
      assert "terminal_state" in branches(path)
    end

    test "emits pr_ready_short_circuit when PR attached and ready", %{ledger_path: path} do
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _issue -> true end)

      issue =
        build_issue(
          has_pr_attachment: true,
          repos: [%{name: "fe-next-app", pr: %{url: "https://github.com/o/r/pull/1"}}]
        )

      state = running_state(issue)

      Reconcile.run(state, %{
        terminate_fn: record_terminate(self()),
        pr_sync_fn: record_pr_sync(self()),
        fetch_fn: fn _ids -> {:ok, [issue]} end
      })

      assert "pr_ready_short_circuit" in branches(path)
    end

    test "emits active_state branch for routable issue in active state", %{ledger_path: path} do
      issue = build_issue(state: "In Development")
      state = running_state(issue)

      Reconcile.run(state, %{
        terminate_fn: record_terminate(self()),
        pr_sync_fn: record_pr_sync(self()),
        fetch_fn: fn _ids -> {:ok, [issue]} end
      })

      assert "active_state" in branches(path)
    end

    test "emits no_longer_visible branch when fetch result drops an id", %{ledger_path: path} do
      issue = build_issue()
      state = running_state(issue)

      Reconcile.run(state, %{
        terminate_fn: record_terminate(self()),
        pr_sync_fn: record_pr_sync(self()),
        fetch_fn: fn _ids -> {:ok, []} end
      })

      assert "no_longer_visible" in branches(path)
    end

    test "emits fetch_error when fetch_fn returns {:error, _}", %{ledger_path: path} do
      issue = build_issue()
      state = running_state(issue)

      Reconcile.run(state, %{
        terminate_fn: record_terminate(self()),
        pr_sync_fn: record_pr_sync(self()),
        fetch_fn: fn _ids -> {:error, :boom} end
      })

      events = decisions(path) |> Enum.map(& &1["event"])
      assert "reconcile.fetch_error" in events
    end
  end
end
