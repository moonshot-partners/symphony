%{
  issue: %{
    id: "sodev-837",
    identifier: "SODEV-837",
    title: "Fix mobile checkout layout",
    description: "## AC\n\n- [ ] Mobile checkout renders correctly on iPhone 12\n",
    url: "https://linear.app/schoolsout/issue/SODEV-837",
    state: "Scheduled",
    has_pr_attachment: false,
    blocked_by: []
  },
  events: [
    {:agent_dispatched, %{turn: 1}},
    {:pr_opened, %{number: 520}},
    {:qa_blocked, %{reason: "selector not found"}}
  ],
  expected: %{
    final_state: "On Hold",
    gate_verdicts: [],
    turn_count: 1,
    error_class: :qa_blocked,
    pr_outcome: "pr_open",
    decision_event_count_min: 1,
    decision_event_count_max: 10
  }
}
