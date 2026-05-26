%{
  issue: %{
    id: "7d45207b-b48f-4be2-99f8-960dfe1115e2",
    identifier: "SODEV-824",
    title: "schoolsout: PR cleared after iterations",
    description: "Calibrated from Hetzner decisions.jsonl ts=2026-05-25T01:47:29→01:47:33 and runs.jsonl ts=2026-05-25T01:47:22.",
    url: "https://linear.app/moonshotpartners/issue/SODEV-824",
    state: "In Development",
    has_pr_attachment: true,
    blocked_by: []
  },
  events: [
    {:reconcile_decision, %{action: "pr_sync+terminate", branch: "pr_ready_short_circuit", linear_state: "In Development"}},
    {:workpad_pr_sync_route, %{branch: "default_complete", target_state: "In Code Review", red_checks: []}}
  ],
  run: %{
    turns: 0,
    outcome: "pr_open",
    tokens_in: 0,
    tokens_out: 0,
    retries: 0,
    pr_url: "https://github.com/schoolsoutapp/schools-out/pull/923"
  },
  expected: %{
    final_state: "In Code Review",
    gate_verdicts: [],
    turn_count: 0,
    error_class: nil,
    pr_outcome: "pr_open",
    decision_event_count: 2
  }
}
