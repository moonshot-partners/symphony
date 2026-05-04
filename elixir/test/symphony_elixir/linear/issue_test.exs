defmodule SymphonyElixir.Linear.IssueTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue

  test "Issue struct exposes repos, state_type, column" do
    issue = %Issue{
      id: "i1",
      identifier: "SODEV-1",
      repos: [%{name: "symphony", pr: nil}],
      state_type: "started",
      column: "in_progress"
    }

    assert issue.repos == [%{name: "symphony", pr: nil}]
    assert issue.state_type == "started"
    assert issue.column == "in_progress"
  end

  test "Issue struct defaults repos to [] and state_type/column to nil" do
    issue = %Issue{}
    assert issue.repos == []
    assert issue.state_type == nil
    assert issue.column == nil
  end

  test "Issue struct no longer carries pr_url" do
    refute Map.has_key?(%Issue{}, :pr_url)
  end
end
