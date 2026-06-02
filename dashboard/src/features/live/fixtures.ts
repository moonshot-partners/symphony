import type { LivePayload } from "./contract";

/**
 * Mock live snapshot so the cockpit runs locally without the Elixir API. Keyed
 * to the MOCK_BOARD running ticket (SODEV-956) so the overlay shows in mock
 * mode. Swapping to the real API is an env flip, not a rewrite.
 */
export const MOCK_LIVE: LivePayload = {
  available: true,
  agents: [
    {
      id: "SODEV-956",
      issueId: "uuid-956",
      state: "In Progress",
      turn: 7,
      lastAction: "Running unit tests + lint",
      lastEvent: "tool_use",
      runtimeSeconds: 142,
      startedAt: "2026-05-30T12:44:00Z",
      lastActivityAt: "2026-05-30T12:46:22Z",
      tokens: { in: 48200, out: 9100, total: 57300 },
      sessionId: "sess-956",
      workerHost: "hetzner-1",
      costUsd: 0.42,
      traceUrl: "https://cloud.langfuse.com/trace/live-trace-956",
    },
  ],
  retrying: [],
  polling: { checking: false, nextPollInMs: 8000, intervalMs: 30000 },
};
