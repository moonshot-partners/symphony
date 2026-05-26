%{
  issue: %{
    id: "ad7ded24-e794-4c09-8864-bc6ffeba336c",
    identifier: "SODEV-843",
    title: "schoolsout: real production happy path",
    description: "Calibrated from Hetzner decisions.jsonl ts=2026-05-23T15:45:14→16:35:55 and runs.jsonl ts=2026-05-23T16:00:37.",
    url: "https://linear.app/moonshotpartners/issue/SODEV-843",
    state: "In Development",
    has_pr_attachment: true,
    blocked_by: []
  },
  events: [
    {:reconcile_decision, %{action: "refresh", branch: "active_state", linear_state: "In Development"}},
    {:reconcile_decision, %{action: "refresh", branch: "has_pr_attachment_active", linear_state: "In Development"}},
    {:reconcile_decision, %{action: "pr_sync+terminate", branch: "pr_ready_short_circuit", linear_state: "In Development"}},
    {:workpad_pr_sync_route, %{branch: "default_complete", target_state: "In Code Review", red_checks: []}}
  ],
  run: %{
    turns: 3,
    outcome: "pr_open",
    tokens_in: 38_954,
    tokens_out: 0,
    retries: 0,
    pr_url: "https://github.com/schoolsoutapp/fe-next-app/pull/589"
  },
  expected: %{
    final_state: "In Code Review",
    gate_verdicts: [],
    turn_count: 3,
    error_class: nil,
    pr_outcome: "pr_open",
    decision_event_count: 4
  }
}
