%{
  issue: %{
    id: "14abdfa8-2df3-4949-bda0-205c538c5b1f",
    identifier: "SODEV-892",
    title: "schoolsout: scope-discipline plus review red",
    description: "Calibrated from Hetzner decisions.jsonl ts=2026-05-23T15:45:49→16:18:10 and runs.jsonl ts=2026-05-23T16:00:41.",
    url: "https://linear.app/moonshotpartners/issue/SODEV-892",
    state: "In Development",
    has_pr_attachment: true,
    blocked_by: []
  },
  events: [
    {:reconcile_decision, %{action: "refresh", branch: "active_state", linear_state: "In Development"}},
    {:reconcile_decision, %{action: "refresh", branch: "has_pr_attachment_active", linear_state: "In Development"}},
    {:reconcile_decision, %{action: "pr_sync+terminate", branch: "pr_ready_short_circuit", linear_state: "In Development"}},
    {:workpad_pr_sync_route,
     %{
       branch: "ci_red",
       target_state: "On Hold / Blocked",
       red_checks: ["scope-discipline", "review", "review", "qa-evidence", "qa-evidence"]
     }}
  ],
  run: %{
    turns: 4,
    outcome: "pr_open",
    tokens_in: 10_608,
    tokens_out: 0,
    retries: 0,
    pr_url: "https://github.com/schoolsoutapp/fe-next-app/pull/587"
  },
  expected: %{
    final_state: "On Hold / Blocked",
    gate_verdicts: [
      {"scope-discipline", :reject},
      {"review", :reject},
      {"review", :reject},
      {"qa-evidence", :reject},
      {"qa-evidence", :reject}
    ],
    turn_count: 4,
    error_class: :ci_red,
    pr_outcome: "pr_open",
    decision_event_count: 4
  }
}
