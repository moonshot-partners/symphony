defmodule SymphonyElixir.Linear.NormalizerLabelTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Client

  defp raw_issue(labels) do
    %{
      "id" => "issue-1",
      "identifier" => "SODEV-1",
      "title" => "Test",
      "description" => nil,
      "priority" => nil,
      "state" => %{"name" => "In Development"},
      "branchName" => nil,
      "url" => "https://linear.app/test/SODEV-1",
      "assignee" => nil,
      "labels" => %{"nodes" => Enum.map(labels, &%{"name" => &1})},
      "inverseRelations" => %{"nodes" => []},
      "attachments" => %{"nodes" => []},
      "createdAt" => nil,
      "updatedAt" => nil
    }
  end

  test "assigned_to_worker is true when issue has the routing label" do
    issue = Client.normalize_issue_for_label_test(raw_issue(["agent"]), "agent")
    assert issue.assigned_to_worker
  end

  test "assigned_to_worker is true with case-insensitive label match" do
    issue = Client.normalize_issue_for_label_test(raw_issue(["Agent"]), "agent")
    assert issue.assigned_to_worker
  end

  test "assigned_to_worker is false when issue lacks the routing label" do
    issue = Client.normalize_issue_for_label_test(raw_issue(["bug", "enhancement"]), "agent")
    refute issue.assigned_to_worker
  end

  test "assigned_to_worker is false when issue has no labels" do
    issue = Client.normalize_issue_for_label_test(raw_issue([]), "agent")
    refute issue.assigned_to_worker
  end

  test "labels are stored downcased on the issue struct" do
    issue = Client.normalize_issue_for_test(raw_issue(["Agent", "BUG"]))
    assert issue.labels == ["agent", "bug"]
  end
end
