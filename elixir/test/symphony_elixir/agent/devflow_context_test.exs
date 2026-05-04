defmodule SymphonyElixir.Agent.DevflowContextTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Agent.DevflowContext
  alias SymphonyElixir.Linear.Issue

  setup do
    previous_root = System.get_env("SYMPHONY_DEVFLOW_ROOT")
    previous_policy = System.get_env("SYMPHONY_DEVFLOW_POLICY")
    previous_prompt = System.get_env("SYMPHONY_DEVFLOW_BASE_PROMPT")

    on_exit(fn ->
      restore_env("SYMPHONY_DEVFLOW_ROOT", previous_root)
      restore_env("SYMPHONY_DEVFLOW_POLICY", previous_policy)
      restore_env("SYMPHONY_DEVFLOW_BASE_PROMPT", previous_prompt)
    end)

    :ok
  end

  test "returns nil when SYMPHONY_DEVFLOW_ROOT is unset" do
    System.delete_env("SYMPHONY_DEVFLOW_ROOT")

    issue = %Issue{
      id: "id",
      identifier: "MT-1",
      title: "title",
      url: "https://example.org/MT-1"
    }

    assert DevflowContext.from_issue_and_env(issue) == nil
  end

  test "builds context map from issue when SYMPHONY_DEVFLOW_ROOT is set" do
    System.put_env("SYMPHONY_DEVFLOW_ROOT", "/tmp/devflow-lite")
    System.delete_env("SYMPHONY_DEVFLOW_POLICY")
    System.delete_env("SYMPHONY_DEVFLOW_BASE_PROMPT")

    issue = %Issue{
      id: "id",
      identifier: "MT-2",
      title: "Wire devflow",
      url: "https://example.org/MT-2"
    }

    ctx = DevflowContext.from_issue_and_env(issue)

    assert is_map(ctx)
    assert ctx["devflowRoot"] == "/tmp/devflow-lite"
    assert ctx["issueIdentifier"] == "MT-2"
    assert ctx["issueTitle"] == "Wire devflow"
    assert ctx["issueUrl"] == "https://example.org/MT-2"
    assert ctx["policy"] == "auto_deny"
    assert ctx["basePrompt"] == ""
  end

  test "honours SYMPHONY_DEVFLOW_POLICY and SYMPHONY_DEVFLOW_BASE_PROMPT overrides" do
    System.put_env("SYMPHONY_DEVFLOW_ROOT", "/tmp/devflow-lite")
    System.put_env("SYMPHONY_DEVFLOW_POLICY", "log_and_allow")
    System.put_env("SYMPHONY_DEVFLOW_BASE_PROMPT", "You are an unattended Symphony agent.")

    issue = %Issue{
      id: "id",
      identifier: "MT-3",
      title: "policy test",
      url: ""
    }

    ctx = DevflowContext.from_issue_and_env(issue)

    assert ctx["policy"] == "log_and_allow"
    assert ctx["basePrompt"] == "You are an unattended Symphony agent."
  end

  test "rejects unknown policy values with a clear error" do
    System.put_env("SYMPHONY_DEVFLOW_ROOT", "/tmp/devflow-lite")
    System.put_env("SYMPHONY_DEVFLOW_POLICY", "nonsense")

    issue = %Issue{id: "id", identifier: "MT-4", title: "x", url: ""}

    assert_raise ArgumentError, ~r/SYMPHONY_DEVFLOW_POLICY/, fn ->
      DevflowContext.from_issue_and_env(issue)
    end
  end

  test "coerces nil issue url to empty string for shim contract" do
    System.put_env("SYMPHONY_DEVFLOW_ROOT", "/tmp/devflow-lite")

    issue = %Issue{id: "id", identifier: "MT-5", title: "x", url: nil}

    ctx = DevflowContext.from_issue_and_env(issue)
    assert ctx["issueUrl"] == ""
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
