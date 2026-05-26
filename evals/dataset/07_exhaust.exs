%{
  issue: %{
    id: "sodev-903",
    identifier: "SODEV-903",
    title: "Hit turn cap with green CI",
    description: "## AC\n\n- [ ] Some requirement\n",
    url: "https://linear.app/schoolsout/issue/SODEV-903",
    state: "Scheduled",
    has_pr_attachment: false,
    blocked_by: []
  },
  events: [
    {:agent_dispatched, %{turn: 1}},
    {:agent_dispatched, %{turn: 2}},
    {:agent_dispatched, %{turn: 3}},
    {:pr_opened, %{number: 702}},
    {:ci_green, %{}},
    {:exhaust, %{reason: "turn_cap"}},
    {:state_transition, %{to: "In Code Review"}}
  ],
  expected: %{
    final_state: "In Code Review",
    gate_verdicts: [],
    turn_count: 3,
    error_class: :exhaust,
    pr_outcome: "pr_open",
    decision_event_count_min: 4,
    decision_event_count_max: 15
  }
}
