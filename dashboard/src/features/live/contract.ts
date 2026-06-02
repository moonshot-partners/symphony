import { z } from "zod";

/**
 * The live contract. Mirrors the cockpit `/live` payload (Elixir
 * `Cockpit.LiveView`), the in-memory runtime snapshot of what each agent is
 * doing right now. This is the live-telemetry regime, kept apart from the
 * board's slow, cached structure on purpose: the board carries tickets/CI/PRs,
 * this carries the turn/action/runtime that change every turn. The browser
 * polls this fast and overlays it onto the matching board card by `id`.
 */

export const LiveTokens = z.object({
  in: z.number(),
  out: z.number(),
  total: z.number(),
});

// One row of the live activity timeline: the orchestrator event tag, its
// human one-liner, and when it happened. Newest first.
export const LiveEvent = z.object({
  event: z.string(),
  action: z.string().nullable(),
  at: z.string().nullable(),
});

export const LiveAgent = z.object({
  id: z.string(), // ticket identifier, matches Ticket.id ("SODEV-956")
  issueId: z.string(), // internal tracker id
  state: z.string(), // raw tracker state (pipeline position)
  turn: z.number().int().nullable(),
  lastAction: z.string().nullable(),
  lastEvent: z.string().nullable(),
  runtimeSeconds: z.number().nullable(),
  startedAt: z.string().nullable(),
  lastActivityAt: z.string().nullable(),
  tokens: LiveTokens,
  sessionId: z.string().nullable(),
  workerHost: z.string().nullable(),
  costUsd: z.number().nullable(), // cumulative run cost so far, null before first update
  traceUrl: z.string().url().nullable(), // deep link to the in-flight Langfuse trace
  events: z.array(LiveEvent).default([]), // recent activity timeline, newest first
});

export const LiveRetry = z.object({
  id: z.string(),
  attempt: z.number().int(),
  dueInMs: z.number().int(),
  error: z.string().nullable(),
});

export const LivePolling = z
  .object({
    checking: z.boolean(),
    nextPollInMs: z.number().int().nullable(),
    intervalMs: z.number().int().nullable(),
  })
  .nullable();

export const LivePayload = z.object({
  // false when the orchestrator was unreachable/busy, so the UI can tell "no
  // agents running" apart from "could not read the orchestrator".
  available: z.boolean(),
  agents: z.array(LiveAgent),
  retrying: z.array(LiveRetry),
  polling: LivePolling,
});

export type LiveEvent = z.infer<typeof LiveEvent>;
export type LiveAgent = z.infer<typeof LiveAgent>;
export type LiveRetry = z.infer<typeof LiveRetry>;
export type LivePayload = z.infer<typeof LivePayload>;
