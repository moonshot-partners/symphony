%{
  issue: %{
    id: "sodev-839",
    identifier: "SODEV-839",
    title: "Migrate footer to design tokens",
    description: "## AC\n\n- [ ] Replace hardcoded colors with tokens\n- [ ] Add visual regression test\n",
    url: "https://linear.app/schoolsout/issue/SODEV-839",
    state: "Scheduled",
    has_pr_attachment: false,
    blocked_by: []
  },
  events: [
    {:agent_dispatched, %{turn: 1}},
    {:pr_opened, %{number: 595, branch: "fix/sodev-839-footer-tokens"}},
    {:gate_c_pass, %{turn: 1}},
    {:gate_d_pass, %{turn: 2}},
    {:ci_green, %{}},
    {:pr_review_clean, %{}},
    {:pr_merged, %{at: "2026-05-25T12:00:00Z"}}
  ],
  expected: %{
    final_state: "In Code Review",
    gate_verdicts: [{"gate_c", :pass}, {"gate_d", :pass}],
    turn_count: 1,
    error_class: nil,
    pr_outcome: "merged",
    decision_event_count_min: 5,
    decision_event_count_max: 20
  }
}
