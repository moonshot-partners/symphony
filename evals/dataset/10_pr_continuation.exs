%{
  issue: %{
    id: "sodev-906",
    identifier: "SODEV-906",
    title: "Re-dispatch with has_pr_attachment continues same branch",
    description: "## AC\n\n- [ ] Some requirement\n",
    url: "https://linear.app/schoolsout/issue/SODEV-906",
    state: "Scheduled",
    has_pr_attachment: true,
    blocked_by: []
  },
  events: [
    {:agent_dispatched, %{turn: 1, has_pr_attachment: true}},
    {:pr_updated, %{number: 705}},
    {:ci_green, %{}},
    {:pr_review_clean, %{}},
    {:pr_merged, %{}}
  ],
  expected: %{
    final_state: "In Code Review",
    gate_verdicts: [],
    turn_count: 1,
    error_class: nil,
    pr_outcome: "merged",
    decision_event_count_min: 3,
    decision_event_count_max: 15
  }
}
