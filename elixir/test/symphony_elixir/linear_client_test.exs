defmodule SymphonyElixir.LinearClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Client

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
end
