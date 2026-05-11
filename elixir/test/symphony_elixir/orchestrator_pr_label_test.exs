defmodule SymphonyElixir.OrchestratorPrLabelTest do
  use SymphonyElixir.TestSupport

  describe "parse_github_pr_url_for_test/1" do
    test "parses standard GitHub PR URL" do
      url = "https://github.com/schoolsoutapp/schools-out/pull/789"
      assert Orchestrator.parse_github_pr_url_for_test(url) == {:ok, "schoolsoutapp", "schools-out", 789}
    end

    test "parses URL with trailing slash" do
      url = "https://github.com/schoolsoutapp/fe-next-app/pull/460/"
      assert Orchestrator.parse_github_pr_url_for_test(url) == {:ok, "schoolsoutapp", "fe-next-app", 460}
    end

    test "returns error for non-PR URL" do
      assert Orchestrator.parse_github_pr_url_for_test("https://github.com/owner/repo") == :error
    end

    test "returns error for nil" do
      assert Orchestrator.parse_github_pr_url_for_test(nil) == :error
    end

    test "returns error for non-string" do
      assert Orchestrator.parse_github_pr_url_for_test(42) == :error
    end
  end
end
