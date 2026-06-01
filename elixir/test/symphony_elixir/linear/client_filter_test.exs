defmodule SymphonyElixir.Linear.ClientFilterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Client

  @state_names ["Scheduled", "In Development"]

  test "build_issue_filter with project_slug only" do
    tracker = %{project_slug: "symphony-e2e-sandbox-c2bd55c135ce", team_key: nil}

    assert Client.build_issue_filter(tracker, @state_names) == %{
             state: %{name: %{in: @state_names}},
             project: %{slugId: %{eq: "symphony-e2e-sandbox-c2bd55c135ce"}}
           }
  end

  test "build_issue_filter with team_key only" do
    tracker = %{project_slug: nil, team_key: "SODEV"}

    assert Client.build_issue_filter(tracker, @state_names) == %{
             state: %{name: %{in: @state_names}},
             team: %{key: %{eq: "SODEV"}}
           }
  end

  test "build_issue_filter with both project_slug and team_key" do
    tracker = %{project_slug: "data-backlog-1a7949a9388d", team_key: "SODEV"}

    assert Client.build_issue_filter(tracker, @state_names) == %{
             state: %{name: %{in: @state_names}},
             project: %{slugId: %{eq: "data-backlog-1a7949a9388d"}},
             team: %{key: %{eq: "SODEV"}}
           }
  end

  test "build_issue_filter ignores empty strings" do
    tracker = %{project_slug: "", team_key: ""}

    assert Client.build_issue_filter(tracker, @state_names) == %{
             state: %{name: %{in: @state_names}}
           }
  end

  test "build_issue_filter adds a case-insensitive routing-label filter when a label is given" do
    tracker = %{project_slug: nil, team_key: "SODEV"}

    assert Client.build_issue_filter(tracker, @state_names, "agent") == %{
             state: %{name: %{in: @state_names}},
             team: %{key: %{eq: "SODEV"}},
             labels: %{some: %{name: %{eqIgnoreCase: "agent"}}}
           }
  end

  test "build_issue_filter omits the label filter for nil or empty label" do
    tracker = %{project_slug: nil, team_key: "SODEV"}

    base = %{state: %{name: %{in: @state_names}}, team: %{key: %{eq: "SODEV"}}}
    assert Client.build_issue_filter(tracker, @state_names, nil) == base
    assert Client.build_issue_filter(tracker, @state_names, "") == base
  end
end
