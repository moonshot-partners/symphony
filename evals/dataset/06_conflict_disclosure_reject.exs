%{
  issue: %{
    id: "sodev-902",
    identifier: "SODEV-902",
    title: "Touched files outside ## Files",
    description: "## AC\n\n- [ ] Some requirement\n",
    url: "https://linear.app/schoolsout/issue/SODEV-902",
    state: "Scheduled",
    has_pr_attachment: false,
    blocked_by: []
  },
  events: [
    {:agent_dispatched, %{turn: 1}},
    {:pr_opened, %{number: 701}},
    {:gate_c_pass, %{turn: 1}},
    {:conflict_disclosure_reject, %{undisclosed: ["lib/other.ex"]}},
    {:state_transition, %{to: "On Hold"}}
  ],
  expected: %{
    final_state: "On Hold",
    gate_verdicts: [{"gate_c", :pass}],
    turn_count: 1,
    error_class: :conflict_disclosure_reject,
    pr_outcome: "pr_open",
    decision_event_count_min: 2,
    decision_event_count_max: 10
  }
}
