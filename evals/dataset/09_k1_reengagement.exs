%{
  issue: %{
    id: "sodev-905",
    identifier: "SODEV-905",
    title: "claude-pr-review request_changes triggers K=1",
    description: "## AC\n\n- [ ] Some requirement\n",
    url: "https://linear.app/schoolsout/issue/SODEV-905",
    state: "Scheduled",
    has_pr_attachment: false,
    blocked_by: []
  },
  events: [
    {:agent_dispatched, %{turn: 1}},
    {:pr_opened, %{number: 704}},
    {:pr_review_request_changes, %{}},
    {:agent_dispatched, %{turn: 2}},
    {:pr_review_clean, %{}},
    {:pr_merged, %{}}
  ],
  expected: %{
    final_state: "In Code Review",
    gate_verdicts: [],
    turn_count: 2,
    error_class: nil,
    pr_outcome: "merged",
    decision_event_count_min: 4,
    decision_event_count_max: 15
  }
}
