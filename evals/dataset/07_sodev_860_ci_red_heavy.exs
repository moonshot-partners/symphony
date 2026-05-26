%{
  issue: %{
    id: "88933321-6115-4b66-8a43-aa588b2ddf67",
    identifier: "SODEV-860",
    title: "schoolsout: heaviest ci red on record",
    description: "Calibrated from Hetzner decisions.jsonl ts=2026-05-24T16:01:54→16:13:29 and runs.jsonl ts=2026-05-24T16:13:20.",
    url: "https://linear.app/moonshotpartners/issue/SODEV-860",
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
       red_checks: ["review", "review", "review", "qa-evidence", "qa-evidence", "qa-evidence", "qa-evidence"]
     }}
  ],
  run: %{
    turns: 1,
    outcome: "pr_open",
    tokens_in: 0,
    tokens_out: 0,
    retries: 0,
    pr_url: "https://github.com/schoolsoutapp/fe-next-app/pull/591"
  },
  expected: %{
    final_state: "On Hold / Blocked",
    gate_verdicts: [
      {"review", :reject},
      {"review", :reject},
      {"review", :reject},
      {"qa-evidence", :reject},
      {"qa-evidence", :reject},
      {"qa-evidence", :reject},
      {"qa-evidence", :reject}
    ],
    turn_count: 1,
    error_class: :ci_red,
    pr_outcome: "pr_open",
    decision_event_count: 4
  }
}
