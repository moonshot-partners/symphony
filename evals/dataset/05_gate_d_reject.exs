%{
  issue: %{
    id: "sodev-901",
    identifier: "SODEV-901",
    title: "Unbacked verified claim",
    description: "## AC\n\n- [ ] Some requirement\n",
    url: "https://linear.app/schoolsout/issue/SODEV-901",
    state: "Scheduled",
    has_pr_attachment: false,
    blocked_by: []
  },
  events: [
    {:agent_dispatched, %{turn: 1}},
    {:pr_opened, %{number: 700}},
    {:gate_c_pass, %{turn: 1}},
    {:gate_d_reject, %{reason: "unbacked verified claim"}}
  ],
  expected: %{
    final_state: "On Hold",
    gate_verdicts: [{"gate_c", :pass}, {"gate_d", :reject}],
    turn_count: 1,
    error_class: :gate_d_reject,
    pr_outcome: "pr_open",
    decision_event_count_min: 2,
    decision_event_count_max: 10
  }
}
