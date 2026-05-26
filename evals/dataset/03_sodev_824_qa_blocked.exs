%{
  issue: %{
    id: "7d45207b-b48f-4be2-99f8-960dfe1115e2",
    identifier: "SODEV-824",
    title: "schoolsout: agent self-reported qa block",
    description: "Calibrated from Hetzner decisions.jsonl ts=2026-05-23T15:44:52→16:33:48 and runs.jsonl ts=2026-05-23T16:00:36.",
    url: "https://linear.app/moonshotpartners/issue/SODEV-824",
    state: "In Development",
    has_pr_attachment: true,
    blocked_by: []
  },
  events: [
    {:reconcile_decision, %{action: "refresh", branch: "active_state", linear_state: "In Development"}},
    {:reconcile_decision, %{action: "refresh", branch: "has_pr_attachment_active", linear_state: "In Development"}},
    {:reconcile_decision, %{action: "pr_sync+terminate", branch: "pr_ready_short_circuit", linear_state: "In Development"}},
    {:workpad_pr_sync_route, %{branch: "qa_blocked", target_state: "On Hold / Blocked", red_checks: []}}
  ],
  run: %{
    turns: 7,
    outcome: "pr_open",
    tokens_in: 40_881,
    tokens_out: 0,
    retries: 0,
    pr_url: "https://github.com/schoolsoutapp/fe-next-app/pull/588"
  },
  expected: %{
    final_state: "On Hold / Blocked",
    gate_verdicts: [{"qa", :reject}],
    turn_count: 7,
    error_class: :qa_blocked,
    pr_outcome: "pr_open",
    decision_event_count: 4
  }
}
