defmodule SymphonyElixir.Linear.BoardClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.BoardClient

  test "fetch_all_issues_by_states_for_test issues GraphQL call without project filter" do
    parent = self()

    graphql_fun = fn query, vars ->
      send(parent, {:graphql, query, vars})
      {:ok, %{"data" => %{"issues" => %{"nodes" => []}}}}
    end

    assert {:ok, []} =
             BoardClient.fetch_all_issues_by_states_for_test(
               ["Backlog", "Todo"],
               100,
               graphql_fun
             )

    assert_received {:graphql, query, vars}
    refute Map.has_key?(vars, :projectSlug)
    refute String.contains?(query, "projectSlug")
    assert vars.stateNames == ["Backlog", "Todo"]
    assert vars.first == 100
  end

  test "fetch_all_issues_by_states_for_test parses issues from multiple teams" do
    body = %{
      "data" => %{
        "issues" => %{
          "nodes" => [
            %{
              "id" => "a",
              "identifier" => "MOM-1",
              "title" => "mom one",
              "state" => %{"name" => "Backlog", "type" => "backlog"},
              "url" => "https://linear.app/x/issue/MOM-1",
              "createdAt" => "2026-04-29T00:00:00Z",
              "updatedAt" => "2026-04-29T00:00:00Z"
            },
            %{
              "id" => "b",
              "identifier" => "SODEV-1",
              "title" => "sodev one",
              "state" => %{"name" => "Todo", "type" => "unstarted"},
              "url" => "https://linear.app/x/issue/SODEV-1",
              "createdAt" => "2026-04-30T00:00:00Z",
              "updatedAt" => "2026-04-30T00:00:00Z"
            }
          ]
        }
      }
    }

    graphql_fun = fn _q, _v -> {:ok, body} end

    {:ok, issues} =
      BoardClient.fetch_all_issues_by_states_for_test(["Backlog", "Todo"], 100, graphql_fun)

    assert Enum.map(issues, & &1.identifier) == ["MOM-1", "SODEV-1"]
  end

  test "fetch_all_issues_by_states_for_test short-circuits on empty state list" do
    graphql_fun = fn _q, _v -> flunk("graphql_fun must not be invoked") end
    assert {:ok, []} = BoardClient.fetch_all_issues_by_states_for_test([], 100, graphql_fun)
  end

  test "fetch_all_issues_by_states_for_test forwards limit to GraphQL first parameter" do
    parent = self()

    graphql_fun = fn _q, vars ->
      send(parent, {:vars, vars})
      {:ok, %{"data" => %{"issues" => %{"nodes" => []}}}}
    end

    {:ok, []} = BoardClient.fetch_all_issues_by_states_for_test(["Backlog"], 25, graphql_fun)
    assert_received {:vars, %{first: 25}}
  end
end
