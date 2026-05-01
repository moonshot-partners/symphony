defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})

      case Process.get({__MODULE__, :fetch_issues_by_states}) do
        fun when is_function(fun, 1) -> fun.(states)
        _ -> {:ok, states}
      end
    end

    def fetch_all_issues_by_states(states, limit) do
      send(self(), {:fetch_all_issues_by_states_called, states, limit})

      case fetch_issues_by_states(states) do
        {:ok, issues} -> {:ok, Enum.take(issues, limit)}
        other -> other
      end
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    linear_board_client_module =
      Application.get_env(:symphony_elixir, :linear_board_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end

      if is_nil(linear_board_client_module) do
        Application.delete_env(:symphony_elixir, :linear_board_client_module)
      else
        Application.put_env(
          :symphony_elixir,
          :linear_board_client_module,
          linear_board_client_module
        )
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])

    assert {:ok, "memory-comment-issue-1"} =
             SymphonyElixir.Tracker.create_comment("issue-1", "comment")

    assert :ok = SymphonyElixir.Tracker.update_comment("memory-comment-issue-1", "edited")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_comment_update, "memory-comment-issue-1", "edited"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert {:ok, "memory-comment-issue-1"} = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_comment("memory-comment-issue-1", "muted")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok,
       %{
         "data" => %{
           "commentCreate" => %{"success" => true, "comment" => %{"id" => "comment-1"}}
         }
       }}
    )

    assert {:ok, "comment-1"} = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "missing-id")

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.update_comment("comment-1", "edited")

    assert_receive {:graphql_called, update_comment_query, %{body: "edited", commentId: "comment-1"}}

    assert update_comment_query =~ "commentUpdate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentUpdate" => %{"success" => false}}}}
    )

    assert {:error, :comment_update_failed} = Adapter.update_comment("comment-1", "no")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})
    assert {:error, :boom} = Adapter.update_comment("comment-1", "fail")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_update_failed} = Adapter.update_comment("comment-1", "empty")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "agent_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "logs" => %{"agent_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "healthz returns 200 ok without orchestrator dependency" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :HealthzOrchestrator),
      snapshot_timeout_ms: 5
    )

    payload = json_response(get(build_conn(), "/healthz"), 200)
    assert payload == %{"status" => "ok"}

    assert json_response(post(build_conn(), "/healthz", %{}), 405) == %{
             "error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}
           }
  end

  test "http server serves headless API, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1}

    healthz = Req.get!("http://127.0.0.1:#{port}/healthz")
    assert healthz.status == 200
    assert healthz.body == %{"status" => "ok"}

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  describe "board_payload/2" do
    test "groups Linear issues by column and joins with running snapshot" do
      Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
      Process.put({FakeLinearClient, :graphql_result}, nil)

      issues = [
        %SymphonyElixir.Linear.Issue{
          id: "i1",
          identifier: "SODEV-1",
          title: "Todo task",
          state: "Todo",
          url: "u1",
          priority: 2,
          assignee_id: "a1",
          assignee_name: "Ana",
          assignee_display_name: "ana",
          labels: ["seo"],
          has_pr_attachment: false
        },
        %SymphonyElixir.Linear.Issue{
          id: "i2",
          identifier: "SODEV-2",
          title: "Active task",
          state: "In Progress",
          url: "u2",
          priority: 1,
          assignee_id: "a2",
          assignee_name: "Bob",
          assignee_display_name: "bob",
          labels: [],
          has_pr_attachment: true
        },
        %SymphonyElixir.Linear.Issue{
          id: "i3",
          identifier: "SODEV-3",
          title: "Done task",
          state: "Done",
          url: "u3",
          priority: 3,
          assignee_id: nil,
          assignee_name: nil,
          assignee_display_name: nil,
          labels: [],
          has_pr_attachment: true
        }
      ]

      orch_name = :"orch_#{System.unique_integer([:positive])}"

      {:ok, _fake_orch} =
        StaticOrchestrator.start_link(
          name: orch_name,
          snapshot: %{
            running: [
              %{
                issue_id: "i2",
                identifier: "SODEV-2",
                state: "In Progress",
                session_id: "sess-1",
                turn_count: 7,
                last_agent_event: :tool_use,
                last_agent_message: "writing test",
                last_agent_timestamp: ~U[2026-04-30 19:00:00Z],
                started_at: ~U[2026-04-30 18:55:00Z],
                agent_input_tokens: 1000,
                agent_output_tokens: 1400,
                agent_total_tokens: 2400
              }
            ],
            retrying: [],
            agent_totals: %{},
            rate_limits: nil
          }
        )

      payload =
        SymphonyElixirWeb.Presenter.board_payload(
          fn -> {:ok, issues} end,
          orch_name,
          1_000
        )

      assert is_binary(payload.generated_at)
      assert length(payload.columns) == 4
      [todo, in_progress, in_review, done] = payload.columns

      assert todo.key == "todo"
      assert Enum.map(todo.issues, & &1.identifier) == ["SODEV-1"]

      assert in_progress.key == "in_progress"
      assert [active] = in_progress.issues
      assert active.identifier == "SODEV-2"
      assert active.agent_status.running == true
      assert active.agent_status.turn_count == 7
      assert active.agent_status.last_event == "writing test"

      assert in_review.key == "in_review"
      assert in_review.issues == []

      assert done.key == "done"
      assert hd(done.issues).agent_status == nil
    end

    test "issue with retrying status maps to non-running agent_status" do
      orch_name = :"orch_#{System.unique_integer([:positive])}"

      {:ok, _fake_orch} =
        StaticOrchestrator.start_link(
          name: orch_name,
          snapshot: %{
            running: [],
            retrying: [
              %{
                issue_id: "i9",
                identifier: "SODEV-9",
                attempt: 2,
                due_in_ms: 5000,
                error: "tool_failed"
              }
            ],
            agent_totals: %{},
            rate_limits: nil
          }
        )

      issues = [
        %SymphonyElixir.Linear.Issue{
          id: "i9",
          identifier: "SODEV-9",
          title: "Retrying task",
          state: "In Progress",
          url: "u9",
          priority: nil,
          assignee_id: nil,
          assignee_name: nil,
          assignee_display_name: nil,
          labels: [],
          has_pr_attachment: false
        }
      ]

      payload =
        SymphonyElixirWeb.Presenter.board_payload(
          fn -> {:ok, issues} end,
          orch_name,
          1_000
        )

      [_todo, in_progress, _in_review, _done] = payload.columns
      [issue] = in_progress.issues
      assert issue.agent_status.running == false
      assert issue.agent_status.retry_attempt == 2
      assert issue.agent_status.retry_reason == "tool_failed"
    end

    test "returns empty columns when linear fetch fails" do
      orch_name = :"orch_#{System.unique_integer([:positive])}"

      {:ok, _fake_orch} =
        StaticOrchestrator.start_link(
          name: orch_name,
          snapshot: %{running: [], retrying: [], agent_totals: %{}, rate_limits: nil}
        )

      payload =
        SymphonyElixirWeb.Presenter.board_payload(
          fn -> {:error, :missing_linear_api_token} end,
          orch_name,
          1_000
        )

      assert payload.error.code == "linear_unavailable"
      assert Enum.all?(payload.columns, &(&1.issues == []))
    end
  end

  describe "GET /api/v1/stream" do
    test "emits board_updated SSE on PubSub broadcast" do
      orch_name = Module.concat(__MODULE__, :StreamOrchestrator)

      start_supervised!({StaticOrchestrator, name: orch_name, snapshot: %{running: [], retrying: [], agent_totals: %{}, rate_limits: nil}})

      start_supervised!({HttpServer, host: "127.0.0.1", port: 0, orchestrator: orch_name, snapshot_timeout_ms: 50})

      port = wait_for_bound_port()
      parent = self()

      spawn_link(fn ->
        Req.get!("http://127.0.0.1:#{port}/api/v1/stream",
          receive_timeout: 2_000,
          into: fn {:data, chunk}, acc ->
            send(parent, {:sse_chunk, chunk})
            {:cont, acc}
          end
        )
      end)

      Process.sleep(150)

      assert :ok = SymphonyElixirWeb.ObservabilityPubSub.broadcast_update()

      assert_receive {:sse_chunk, chunk}, 1_500
      assert chunk =~ "event: board_updated"
    end
  end

  describe "CORS for /api/v1/*" do
    test "OPTIONS /api/v1/board returns 204 with allow-origin headers when origin matches" do
      orch_name = Module.concat(__MODULE__, :CorsPreflightOrchestrator)

      {:ok, _orch} =
        StaticOrchestrator.start_link(
          name: orch_name,
          snapshot: %{running: [], retrying: [], agent_totals: %{}, rate_limits: nil}
        )

      start_test_endpoint(orchestrator: orch_name, snapshot_timeout_ms: 50)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("origin", "http://localhost:3000")
        |> Plug.Conn.put_req_header("access-control-request-method", "GET")
        |> dispatch(@endpoint, :options, "/api/v1/board")

      assert conn.status == 204

      assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") ==
               ["http://localhost:3000"]

      [methods] = Plug.Conn.get_resp_header(conn, "access-control-allow-methods")
      assert "GET" in String.split(methods, ", ")
    end

    test "GET /api/v1/board includes allow-origin when origin matches" do
      Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
      Process.put({FakeLinearClient, :graphql_result}, nil)
      Process.put({FakeLinearClient, :fetch_issues_by_states}, fn _ -> {:ok, []} end)

      orch_name = Module.concat(__MODULE__, :CorsBoardOrchestrator)

      {:ok, _orch} =
        StaticOrchestrator.start_link(
          name: orch_name,
          snapshot: %{running: [], retrying: [], agent_totals: %{}, rate_limits: nil}
        )

      start_test_endpoint(orchestrator: orch_name, snapshot_timeout_ms: 50)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("origin", "http://localhost:3000")
        |> get("/api/v1/board")

      assert json_response(conn, 200)

      assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") ==
               ["http://localhost:3000"]
    end
  end

  describe "GET /api/v1/board" do
    test "returns board payload as JSON" do
      Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
      Application.put_env(:symphony_elixir, :linear_board_client_module, FakeLinearClient)
      Process.put({FakeLinearClient, :graphql_result}, nil)

      Process.put({FakeLinearClient, :fetch_issues_by_states}, fn _states ->
        {:ok,
         [
           %SymphonyElixir.Linear.Issue{
             id: "ix",
             identifier: "SODEV-100",
             title: "Test",
             state: "Todo",
             url: "u",
             priority: 1,
             assignee_id: nil,
             assignee_name: nil,
             assignee_display_name: nil,
             labels: [],
             has_pr_attachment: false
           }
         ]}
      end)

      orch_name = Module.concat(__MODULE__, :BoardOrchestrator)

      {:ok, _orch} =
        StaticOrchestrator.start_link(
          name: orch_name,
          snapshot: %{running: [], retrying: [], agent_totals: %{}, rate_limits: nil}
        )

      start_test_endpoint(orchestrator: orch_name, snapshot_timeout_ms: 50)

      payload = json_response(get(build_conn(), "/api/v1/board"), 200)

      assert length(payload["columns"]) == 4

      todo_issues =
        payload["columns"]
        |> Enum.find(&(&1["key"] == "todo"))
        |> Map.fetch!("issues")

      assert hd(todo_issues)["identifier"] == "SODEV-100"
    end
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          agent_pid: nil,
          last_agent_message: "rendered",
          last_agent_timestamp: nil,
          last_agent_event: :notification,
          agent_input_tokens: 4,
          agent_output_tokens: 8,
          agent_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      agent_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
