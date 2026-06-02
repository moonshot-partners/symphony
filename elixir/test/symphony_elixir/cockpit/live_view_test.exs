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
        runtime_seconds: 142,
        agent_cost_usd: 0.18,
        langfuse_trace_id: "trace-abc123"
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
               "workerHost" => "hetzner-1",
               "costUsd" => 0.18,
               "traceUrl" => "https://cloud.langfuse.com/trace/trace-abc123"
             }
    end

    test "builds the live Langfuse trace url from the running trace id" do
      [agent] = LiveView.render(snapshot())["agents"]
      assert agent["traceUrl"] == "https://cloud.langfuse.com/trace/trace-abc123"
    end

    test "yields a nil trace url and nil cost before the agent's first update" do
      snap = snapshot(%{running: [running_entry(%{langfuse_trace_id: nil, agent_cost_usd: nil})]})
      [agent] = LiveView.render(snap)["agents"]

      assert agent["traceUrl"] == nil
      assert agent["costUsd"] == nil
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

  # last_agent_message is summarize_update/1's map (%{event, message, ...}) whose
  # `message` is the raw agent stream payload, not a clean string. A raw map
  # reaching lastAction 502s the BFF, so it must always coerce to a string.
  defp action_for(msg) do
    [agent] = LiveView.render(snapshot(%{running: [running_entry(%{last_agent_message: msg})]}))["agents"]
    agent["lastAction"]
  end

  describe "render/1 lastAction coercion" do
    test "passes a plain string action through" do
      assert action_for("Running unit tests") == "Running unit tests"
    end

    test "extracts the command from a JSON-RPC tool-call summary" do
      msg = %{
        event: "notification",
        message: %{
          "method" => "item/commandExecution/requestApproval",
          "params" => %{"command" => "mix test\nignored second line"}
        },
        timestamp: "2026-06-02T17:04:43Z"
      }

      assert action_for(msg) == "Running mix test"
    end

    test "falls back to the JSON-RPC method's last segment" do
      msg = %{event: "notification", message: %{"method" => "item/agentMessage/delta"}, timestamp: nil}
      assert action_for(msg) == "delta"
    end

    test "falls back to the event tag when the message has nothing usable" do
      assert action_for(%{event: "assistant", message: nil, timestamp: nil}) == "assistant"
    end

    test "yields nil (never a raw map) for an unrecognized message and no event" do
      assert action_for(%{event: nil, message: %{"unknown" => "shape"}, timestamp: nil}) == nil
    end

    test "always produces Jason-encodable output for a raw map message" do
      payload = LiveView.render(snapshot(%{running: [running_entry(%{last_agent_message: %{event: "x", message: %{"a" => 1}}})]}))
      assert is_binary(Jason.encode!(payload))
    end

    test "clips a very long action to 80 characters" do
      clipped = action_for(String.duplicate("x", 200))
      assert String.length(clipped) == 80
      assert String.ends_with?(clipped, "…")
    end

    test "uses a plain-text message carried inside the summary map" do
      assert action_for(%{event: "assistant", message: "Thinking about the fix", timestamp: nil}) ==
               "Thinking about the fix"
    end

    test "yields nil when there is no last message at all" do
      assert action_for(nil) == nil
    end

    test "passes a string activity timestamp through unchanged" do
      [agent] =
        LiveView.render(snapshot(%{running: [running_entry(%{last_agent_timestamp: "2026-06-02T17:04:43Z"})]}))["agents"]

      assert agent["lastActivityAt"] == "2026-06-02T17:04:43Z"
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
