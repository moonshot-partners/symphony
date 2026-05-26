%{
  issue: %{
    id: "sodev-824",
    identifier: "SODEV-824",
    title: "Add prettier check to CI",
    description: "## AC\n\n- [ ] Prettier runs on every PR\n",
    url: "https://linear.app/schoolsout/issue/SODEV-824",
    state: "Scheduled",
    has_pr_attachment: false,
    blocked_by: []
  },
  events: [
    {:agent_dispatched, %{turn: 1}},
    {:pr_opened, %{number: 595}},
    {:ci_red, %{check: "lint"}}
  ],
  expected: %{
    final_state: "On Hold",
    gate_verdicts: [],
    turn_count: 1,
    error_class: :ci_red,
    pr_outcome: "pr_open",
    decision_event_count_min: 1,
    decision_event_count_max: 10
  }
}
