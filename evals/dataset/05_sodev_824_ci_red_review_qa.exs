%{
  issue: %{
    id: "7d45207b-b48f-4be2-99f8-960dfe1115e2",
    identifier: "SODEV-824",
    title: "schoolsout: ci red with review plus qa-evidence",
    description: "Calibrated from Hetzner decisions.jsonl ts=2026-05-24T17:06:05→17:14:33 and runs.jsonl ts=2026-05-24T16:51:09.",
    url: "https://linear.app/moonshotpartners/issue/SODEV-824",
    state: "In Development",
    has_pr_attachment: true,
    blocked_by: []
  },
  events: [
    {:reconcile_decision, %{action: "refresh", branch: "has_pr_attachment_active", linear_state: "In Development"}},
    {:reconcile_decision, %{action: "pr_sync+terminate", branch: "pr_ready_short_circuit", linear_state: "In Development"}},
    {:workpad_pr_sync_route,
     %{
       branch: "ci_red",
       target_state: "On Hold / Blocked",
       red_checks: ["review", "qa-evidence", "qa-evidence"]
     }}
  ],
  run: %{
    turns: 2,
    outcome: "pr_open",
    tokens_in: 34_613,
    tokens_out: 0,
    retries: 0,
    pr_url: "https://github.com/schoolsoutapp/schools-out/pull/921"
  },
  expected: %{
    final_state: "On Hold / Blocked",
    gate_verdicts: [
      {"review", :reject},
      {"qa-evidence", :reject},
      {"qa-evidence", :reject}
    ],
    turn_count: 2,
    error_class: :ci_red,
    pr_outcome: "pr_open",
    decision_event_count: 3
  }
}
