%{
  issue: %{
    id: "85282dd1-e0f3-48b8-adf8-01ca335e6ded",
    identifier: "SODEV-904",
    title: "schoolsout: ticket parked back to backlog",
    description: "Calibrated from Hetzner decisions.jsonl ts=2026-05-21T20:30:40→20:33:47 and runs.jsonl ts=2026-05-21T20:30:34.",
    url: "https://linear.app/moonshotpartners/issue/SODEV-904",
    state: "In Development",
    has_pr_attachment: false,
    blocked_by: []
  },
  events: [
    {:reconcile_decision, %{action: "refresh", branch: "active_state", linear_state: "In Development"}},
    {:reconcile_decision, %{action: "terminate", branch: "not_routable", linear_state: "Backlog"}}
  ],
  run: %{
    turns: 1,
    outcome: "no_pr",
    tokens_in: 24,
    tokens_out: 0,
    retries: 0,
    pr_url: nil
  },
  expected: %{
    final_state: "Backlog",
    gate_verdicts: [],
    turn_count: 1,
    error_class: :not_routable,
    pr_outcome: "no_pr",
    decision_event_count: 2
  }
}
