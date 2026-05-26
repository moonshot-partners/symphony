%{
  issue: %{
    id: "sodev-904",
    identifier: "SODEV-904",
    title: "qa_blocked short-circuits",
    description: "## AC\n\n- [ ] Some requirement\n",
    url: "https://linear.app/schoolsout/issue/SODEV-904",
    state: "Scheduled",
    has_pr_attachment: false,
    blocked_by: []
  },
  events: [
    {:agent_dispatched, %{turn: 1}},
    {:pr_opened, %{number: 703}},
    {:qa_blocked, %{}},
    {:agent_done_graceful, %{}}
  ],
  expected: %{
    final_state: "On Hold",
    gate_verdicts: [],
    turn_count: 1,
    error_class: :qa_blocked,
    pr_outcome: "pr_open",
    decision_event_count_min: 2,
    decision_event_count_max: 10
  }
}
