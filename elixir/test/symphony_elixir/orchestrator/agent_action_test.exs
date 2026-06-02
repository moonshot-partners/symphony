defmodule SymphonyElixir.Orchestrator.AgentActionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator.AgentAction

  describe "line/1" do
    test "passes a plain string through" do
      assert AgentAction.line("Editing collection-detail-page.tsx") ==
               "Editing collection-detail-page.tsx"
    end

    test "extracts the command from a bash approval payload" do
      summary = %{
        event: :approval_auto_approved,
        message: %{"method" => "item/commandExecution/requestApproval", "params" => %{"command" => "mix test"}}
      }

      assert AgentAction.line(summary) == "Running mix test"
    end

    test "uses only the command's first line" do
      summary = %{message: %{"params" => %{"command" => "git add .\ngit commit -m x"}}}
      assert AgentAction.line(summary) == "Running git add ."
    end

    test "names the file being edited from a file-change payload" do
      summary = %{
        event: :approval_auto_approved,
        message: %{
          "method" => "item/fileChange/requestApproval",
          "params" => %{"path" => "src/features/board/components/ticket-detail.tsx"}
        }
      }

      assert AgentAction.line(summary) == "Editing ticket-detail.tsx"
    end

    test "surfaces the assistant message text from an agent_message payload" do
      summary = %{
        event: :notification,
        message: %{"method" => "item/agent_message", "params" => %{"text" => "Looking at the snapshot serializer"}}
      }

      assert AgentAction.line(summary) == "Looking at the snapshot serializer"
    end

    test "uses a plain-text message carried inside the summary map" do
      assert AgentAction.line(%{event: :stderr, message: "build warning: unused var"}) ==
               "build warning: unused var"
    end

    test "falls back to the JSON-RPC method's last segment" do
      summary = %{message: %{"method" => "turn/completed"}}
      assert AgentAction.line(summary) == "completed"
    end

    test "falls back to the event tag when the message has nothing usable" do
      summary = %{event: :session_started, message: %{"params" => %{}}}
      assert AgentAction.line(summary) == "session_started"
    end

    test "yields nil for an unusable message and no event" do
      assert AgentAction.line(%{message: %{"params" => %{}}}) == nil
    end

    test "clips a long action to 80 characters" do
      long = String.duplicate("x", 200)
      result = AgentAction.line(long)
      assert String.length(result) == 80
      assert String.ends_with?(result, "…")
    end

    test "yields nil for nil" do
      assert AgentAction.line(nil) == nil
    end
  end
end
