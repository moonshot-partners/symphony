defmodule SymphonyElixir.LinearClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.{Client, Issue}

  describe "build_candidate_filter/3" do
    test "project only scopes by project and state, no label key" do
      filter = Client.build_candidate_filter_for_test("feb-26-abc", nil, ["In Development"])

      assert filter == %{
               state: %{name: %{in: ["In Development"]}},
               project: %{slugId: %{eq: "feb-26-abc"}}
             }

      refute Map.has_key?(filter, :labels)
    end

    test "label only scopes by label and state, no project key" do
      filter = Client.build_candidate_filter_for_test(nil, "agent", ["In Development"])

      assert filter == %{
               state: %{name: %{in: ["In Development"]}},
               labels: %{name: %{eq: "agent"}}
             }

      refute Map.has_key?(filter, :project)
    end

    test "project and label compose into a single filter" do
      filter = Client.build_candidate_filter_for_test("feb-26-abc", "agent", ["Todo", "In Progress"])

      assert filter == %{
               state: %{name: %{in: ["Todo", "In Progress"]}},
               project: %{slugId: %{eq: "feb-26-abc"}},
               labels: %{name: %{eq: "agent"}}
             }
    end

    test "state filter is always present even with no project or label" do
      filter = Client.build_candidate_filter_for_test(nil, nil, ["In Development"])

      assert filter == %{state: %{name: %{in: ["In Development"]}}}
    end
  end

  describe "normalize_issue/2 PR extraction" do
    test "extracts the GitHub PR from the issue attachments" do
      issue = %{
        "identifier" => "SODEV-969",
        "attachments" => %{
          "nodes" => [
            %{"url" => "https://uploads.linear.app/a/b/c"},
            %{"url" => "https://github.com/schoolsoutapp/fe-next-app/pull/658"}
          ]
        }
      }

      assert %Issue{pr: %{url: url, number: 658}} = Client.normalize_issue_for_test(issue)
      assert url == "https://github.com/schoolsoutapp/fe-next-app/pull/658"
    end

    test "pr is nil when no attachment is a GitHub PR" do
      issue = %{
        "identifier" => "SODEV-1",
        "attachments" => %{"nodes" => [%{"url" => "https://uploads.linear.app/x/y/z"}]}
      }

      assert %Issue{pr: nil} = Client.normalize_issue_for_test(issue)
    end

    test "pr is nil when the issue has no attachments" do
      assert %Issue{pr: nil} = Client.normalize_issue_for_test(%{"identifier" => "SODEV-2"})
    end
  end
end
