%{
  issue: %{
    id: "sodev-900",
    identifier: "SODEV-900",
    title: "Skipped AC Extracted",
    description: "## AC\n\n- [ ] Some requirement\n",
    url: "https://linear.app/schoolsout/issue/SODEV-900",
    state: "Scheduled",
    has_pr_attachment: false,
    blocked_by: []
  },
  events: [
    {:agent_dispatched, %{turn: 1}},
    {:gate_c_reject, %{reason: "missing AC Extracted"}}
  ],
  expected: %{
    final_state: "On Hold",
    gate_verdicts: [{"gate_c", :reject}],
    turn_count: 1,
    error_class: :gate_c_reject,
    pr_outcome: "no_pr",
    decision_event_count_min: 1,
    decision_event_count_max: 10
  }
}
