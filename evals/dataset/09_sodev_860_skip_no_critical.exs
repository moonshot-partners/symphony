%{
  issue: %{
    id: "88933321-6115-4b66-8a43-aa588b2ddf67",
    identifier: "SODEV-860",
    title: "schoolsout: pr re-engagement skipped no critical review",
    description: "Calibrated from Hetzner decisions.jsonl ts=2026-05-23T15:46:18→16:46:01 and runs.jsonl ts=2026-05-23T16:00:40.",
    url: "https://linear.app/moonshotpartners/issue/SODEV-860",
    state: "In Development",
    has_pr_attachment: true,
    blocked_by: []
  },
  events: [
    {:reconcile_decision, %{action: "refresh", branch: "active_state", linear_state: "In Development"}},
    {:reconcile_decision, %{action: "refresh", branch: "has_pr_attachment_active", linear_state: "In Development"}},
    {:pr_reengagement_skip_no_critical, %{}}
  ],
  run: %{
    turns: 1,
    outcome: "pr_open",
    tokens_in: 8_409,
    tokens_out: 0,
    retries: 0,
    pr_url: "https://github.com/schoolsoutapp/fe-next-app/pull/590"
  },
  expected: %{
    final_state: "In Development",
    gate_verdicts: [],
    turn_count: 1,
    error_class: :no_critical,
    pr_outcome: "pr_open",
    decision_event_count: 3
  }
}
