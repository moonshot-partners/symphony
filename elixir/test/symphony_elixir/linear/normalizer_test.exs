defmodule SymphonyElixir.Linear.NormalizerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.{Client, Normalizer}

  defp base_issue do
    %{
      "id" => "issue-1",
      "identifier" => "SODEV-1",
      "title" => "Test",
      "description" => "desc",
      "priority" => 2,
      "state" => %{"name" => "In Development"},
      "branchName" => "feature/test",
      "url" => "https://linear.app/test/SODEV-1",
      "assignee" => nil,
      "labels" => %{"nodes" => []},
      "inverseRelations" => %{"nodes" => []},
      "attachments" => %{"nodes" => []},
      "createdAt" => "2026-01-01T00:00:00.000Z",
      "updatedAt" => "2026-01-02T12:30:00.000Z"
    }
  end

  test "parse_priority: integer priority is preserved" do
    issue = Client.normalize_issue_for_test(base_issue())
    assert issue.priority == 2
  end

  test "parse_priority: nil priority becomes nil" do
    issue = Client.normalize_issue_for_test(Map.put(base_issue(), "priority", nil))
    assert is_nil(issue.priority)
  end

  test "parse_datetime: valid ISO 8601 string is parsed to DateTime" do
    issue = Client.normalize_issue_for_test(base_issue())
    assert %DateTime{year: 2026, month: 1, day: 1} = issue.created_at
    assert %DateTime{year: 2026, month: 1, day: 2} = issue.updated_at
  end

  test "parse_datetime: invalid datetime string returns nil" do
    issue = Client.normalize_issue_for_test(Map.put(base_issue(), "createdAt", "not-a-date"))
    assert is_nil(issue.created_at)
  end

  test "assignee_field: extracts name and display_name from assignee map" do
    assignee = %{"id" => "u1", "email" => "a@b.com", "name" => "Alice", "displayName" => "Alice A"}
    issue = Client.normalize_issue_for_test(Map.put(base_issue(), "assignee", assignee))
    assert issue.assignee_name == "Alice"
    assert issue.assignee_display_name == "Alice A"
  end

  test "pr_attachment? returns true when attachments contain a GH PR URL" do
    nodes = [%{"url" => "https://github.com/org/repo/pull/42"}]
    raw = Map.put(base_issue(), "attachments", %{"nodes" => nodes})
    issue = Client.normalize_issue_for_test(raw)
    assert issue.has_pr_attachment
  end

  test "pr_attachment? returns false when attachments have no PR URL" do
    nodes = [%{"url" => "https://linear.app/org/issue/123"}]
    raw = Map.put(base_issue(), "attachments", %{"nodes" => nodes})
    issue = Client.normalize_issue_for_test(raw)
    refute issue.has_pr_attachment
  end

  test "pr_attachment? returns false when attachments key is missing" do
    issue = Client.normalize_issue_for_test(Map.delete(base_issue(), "attachments"))
    refute issue.has_pr_attachment
  end

  test "extract_blockers: 'blocks' relation is included in blocked_by" do
    blocker = %{
      "type" => "blocks",
      "issue" => %{"id" => "b1", "identifier" => "SODEV-2", "state" => %{"name" => "In Progress"}}
    }

    raw = Map.put(base_issue(), "inverseRelations", %{"nodes" => [blocker]})
    issue = Client.normalize_issue_for_test(raw)
    assert [%{id: "b1", identifier: "SODEV-2"}] = issue.blocked_by
  end

  test "extract_blockers: non-'blocks' relation type is ignored" do
    relation = %{
      "type" => "related",
      "issue" => %{"id" => "r1", "identifier" => "SODEV-3", "state" => %{"name" => "Todo"}}
    }

    raw = Map.put(base_issue(), "inverseRelations", %{"nodes" => [relation]})
    issue = Client.normalize_issue_for_test(raw)
    assert issue.blocked_by == []
  end

  test "extract_blockers: returns empty list when inverseRelations key is missing" do
    issue = Client.normalize_issue_for_test(Map.delete(base_issue(), "inverseRelations"))
    assert issue.blocked_by == []
  end

  test "assigned_to_worker? is true when assignee matches filter by email" do
    assignee = %{"id" => "u1", "email" => "alice@example.com", "name" => "Alice", "displayName" => "Alice"}
    raw = Map.put(base_issue(), "assignee", assignee)
    issue = Client.normalize_issue_for_test(raw, "alice@example.com")
    assert issue.assigned_to_worker
  end

  test "assigned_to_worker? is false when assignee does not match filter" do
    assignee = %{"id" => "u1", "email" => "bob@example.com", "name" => "Bob", "displayName" => "Bob"}
    raw = Map.put(base_issue(), "assignee", assignee)
    issue = Client.normalize_issue_for_test(raw, "alice@example.com")
    refute issue.assigned_to_worker
  end

  test "assigned_to_worker? is false when assignee is nil and filter is set" do
    issue = Client.normalize_issue_for_test(base_issue(), "alice@example.com")
    refute issue.assigned_to_worker
  end

  test "normalize_assignee_match_value: whitespace-only name is ignored (treated as nil)" do
    assignee = %{"id" => "u1", "email" => "alice@example.com", "name" => "   ", "displayName" => "Alice"}
    raw = Map.put(base_issue(), "assignee", assignee)
    # name is whitespace-only so only id/email/displayName are candidates; filter by name alone won't match
    issue = Client.normalize_issue_for_test(raw, "alice@example.com")
    assert issue.assigned_to_worker
  end

  test "matches_routing_filter? with both assignee and label — both match" do
    assignee = %{"id" => "u1", "email" => "alice@example.com", "name" => "Alice", "displayName" => "Alice"}
    nodes = [%{"url" => "https://github.com/org/repo/pull/1"}]

    raw =
      base_issue()
      |> Map.put("assignee", assignee)
      |> Map.put("labels", %{"nodes" => [%{"name" => "agent"}]})
      |> Map.put("attachments", %{"nodes" => nodes})

    issue = Client.normalize_issue_for_label_and_assignee_test(raw, "agent", "alice@example.com")
    assert issue.assigned_to_worker
  end

  test "matches_routing_filter? with both assignee and label — label matches, assignee does not" do
    assignee = %{"id" => "u1", "email" => "bob@example.com", "name" => "Bob", "displayName" => "Bob"}

    raw =
      base_issue()
      |> Map.put("assignee", assignee)
      |> Map.put("labels", %{"nodes" => [%{"name" => "agent"}]})

    issue = Client.normalize_issue_for_label_and_assignee_test(raw, "agent", "alice@example.com")
    refute issue.assigned_to_worker
  end

  test "normalize_issue returns nil for non-map input" do
    assert is_nil(Normalizer.normalize_issue("not a map", nil))
  end

  test "normalize_issue with nil routing_filter treats every issue as assigned" do
    issue = Normalizer.normalize_issue(base_issue(), nil)
    assert issue.assigned_to_worker
  end

  test "normalize_issue with unknown routing_filter shape returns assigned_to_worker false" do
    issue = Normalizer.normalize_issue(base_issue(), %{unexpected_key: :value})
    refute issue.assigned_to_worker
  end

  test "extract_repos: attachment node without url key is ignored" do
    raw = Map.put(base_issue(), "attachments", %{"nodes" => [%{"title" => "no-url"}]})
    issue = Client.normalize_issue_for_test(raw)
    assert issue.repos == []
  end

  test "pr_attachment? returns false when attachment node has no url key" do
    raw = Map.put(base_issue(), "attachments", %{"nodes" => [%{"title" => "no-url"}]})
    issue = Client.normalize_issue_for_test(raw)
    refute issue.has_pr_attachment
  end

  test "extract_blockers: inverse_relation without required keys is ignored" do
    raw = Map.put(base_issue(), "inverseRelations", %{"nodes" => [%{"unexpected" => "shape"}]})
    issue = Client.normalize_issue_for_test(raw)
    assert issue.blocked_by == []
  end
end
