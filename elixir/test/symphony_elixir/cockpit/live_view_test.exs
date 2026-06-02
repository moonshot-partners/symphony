defmodule SymphonyElixir.Cockpit.LiveViewTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Cockpit.LiveView

  # A running entry shaped exactly like `Orchestrator.Snapshot.build/3` emits:
  # atom keys, a DateTime for the timestamps, an atom event, a pid, and the
  # internal workspace path that must never reach the browser.
  defp running_entry(overrides \\ %{}) do
    Map.merge(
      %{
        issue_id: "issue-uuid-1",
        identifier: "SODEV-956",
        state: "In Progress",
        worker_host: "hetzner-1",
        workspace_path: "/opt/symphony/work/issue-uuid-1",
        session_id: "sess-abc",
        agent_pid: self(),
        agent_input_tokens: 12_000,
        agent_output_tokens: 3_400,
        agent_total_tokens: 15_400,
        turn_count: 7,
        started_at: ~U[2026-06-02 12:00:00Z],
        last_agent_timestamp: ~U[2026-06-02 12:02:22Z],
        last_agent_message: "Editing collection-detail-page.tsx",
        last_agent_event: :tool_use,
        runtime_seconds: 142
      },
      overrides
    )
  end

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        running: [running_entry()],
        retrying: [],
        agent_totals: %{},
        rate_limits: nil,
        polling: %{checking?: false, next_poll_in_ms: 12_000, poll_interval_ms: 30_000}
      },
      overrides
    )
  end

  describe "render/1 with a snapshot" do
    test "flags the payload available and maps each running agent to camelCase" do
      result = LiveView.render(snapshot())

      assert result["available"] == true
      assert [agent] = result["agents"]

      assert agent == %{
               "id" => "SODEV-956",
               "issueId" => "issue-uuid-1",
               "state" => "In Progress",
               "turn" => 7,
               "lastAction" => "Editing collection-detail-page.tsx",
               "lastEvent" => "tool_use",
               "runtimeSeconds" => 142,
               "startedAt" => "2026-06-02T12:00:00Z",
               "lastActivityAt" => "2026-06-02T12:02:22Z",
               "tokens" => %{"in" => 12_000, "out" => 3_400, "total" => 15_400},
               "sessionId" => "sess-abc",
               "workerHost" => "hetzner-1"
             }
    end

    test "drops the agent pid and workspace path so they never reach the browser" do
      [agent] = LiveView.render(snapshot())["agents"]

      refute Map.has_key?(agent, "agentPid")
      refute Map.has_key?(agent, "pid")
      refute Map.has_key?(agent, "workspacePath")
      refute "/opt/symphony/work/issue-uuid-1" in Map.values(agent)
    end

    test "produces a Jason-encodable payload (no raw DateTime or pid)" do
      json = Jason.encode!(LiveView.render(snapshot()))
      decoded = Jason.decode!(json)

      assert get_in(decoded, ["agents", Access.at(0), "startedAt"]) == "2026-06-02T12:00:00Z"
    end

    test "renders an empty agent list when nothing is running" do
      result = LiveView.render(snapshot(%{running: []}))

      assert result["available"] == true
      assert result["agents"] == []
    end

    test "maps retrying entries with their identifier, attempt, due-in and error" do
      retry = %{
        issue_id: "issue-uuid-2",
        identifier: "SODEV-957",
        attempt: 2,
        due_in_ms: 8_000,
        error: "rate limit",
        worker_host: "hetzner-1",
        workspace_path: "/opt/symphony/work/issue-uuid-2"
      }

      [mapped] = LiveView.render(snapshot(%{retrying: [retry]}))["retrying"]

      assert mapped == %{
               "id" => "SODEV-957",
               "attempt" => 2,
               "dueInMs" => 8_000,
               "error" => "rate limit"
             }
    end

    test "falls back to the internal issue id when a retry has no identifier" do
      retry = %{issue_id: "issue-uuid-3", attempt: 1, due_in_ms: 500}

      [mapped] = LiveView.render(snapshot(%{retrying: [retry]}))["retrying"]

      assert mapped["id"] == "issue-uuid-3"
    end

    test "maps the polling heartbeat" do
      result = LiveView.render(snapshot())

      assert result["polling"] == %{
               "checking" => false,
               "nextPollInMs" => 12_000,
               "intervalMs" => 30_000
             }
    end

    test "tolerates a missing polling sub-map" do
      assert LiveView.render(snapshot(%{polling: nil}))["polling"] == nil
    end

    test "stringifies a non-DateTime timestamp to nil rather than crashing" do
      [agent] = LiveView.render(snapshot(%{running: [running_entry(%{started_at: nil})]}))["agents"]

      assert agent["startedAt"] == nil
    end

    test "renders a nil last event as nil and a string event unchanged" do
      [atom_event] = LiveView.render(snapshot(%{running: [running_entry(%{last_agent_event: :pr_attached})]}))["agents"]
      [nil_event] = LiveView.render(snapshot(%{running: [running_entry(%{last_agent_event: nil})]}))["agents"]
      [string_event] = LiveView.render(snapshot(%{running: [running_entry(%{last_agent_event: "assistant"})]}))["agents"]

      assert atom_event["lastEvent"] == "pr_attached"
      assert nil_event["lastEvent"] == nil
      assert string_event["lastEvent"] == "assistant"
    end
  end

  describe "render/1 when the orchestrator is unreachable" do
    test ":timeout yields an empty payload flagged unavailable" do
      assert LiveView.render(:timeout) == %{
               "available" => false,
               "agents" => [],
               "retrying" => [],
               "polling" => nil
             }
    end

    test ":unavailable yields an empty payload flagged unavailable" do
      assert LiveView.render(:unavailable)["available"] == false
    end
  end
end
