%{
  issue: %{
    id: "sodev-146",
    identifier: "SODEV-146",
    title: "schoolsout: ticket with no pr attached re-engagement skip",
    description: "Calibrated from Hetzner decisions.jsonl ts=2026-05-24T15:57:41→15:59:07. Ticket has no PR attached so pr_reengagement_skip_no_pr fires on every tick; runs.jsonl has no row because no agent session was spawned.",
    url: "https://linear.app/moonshotpartners/issue/SODEV-146",
    state: "In Development",
    has_pr_attachment: false,
    blocked_by: []
  },
  events: [
    {:pr_reengagement_skip_no_pr, %{}}
  ],
  run: %{
    turns: 0,
    outcome: "no_pr",
    tokens_in: 0,
    tokens_out: 0,
    retries: 0,
    pr_url: nil
  },
  expected: %{
    final_state: "In Development",
    gate_verdicts: [],
    turn_count: 0,
    error_class: :no_pr,
    pr_outcome: "no_pr",
    decision_event_count: 1
  }
}
