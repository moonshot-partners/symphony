import { z } from "zod";

/**
 * The board contract. This Zod schema is the single source of truth for the
 * payload that flows Elixir API -> BFF -> browser. Types are inferred from it,
 * and the same schema validates the Elixir response at the BFF boundary, so any
 * contract drift surfaces immediately instead of silently rendering wrong data.
 */

export const AgentStatus = z.enum(["running", "idle"]);

export const CiStatus = z.enum(["pending", "passing", "failing"]);

export const Evidence = z.object({
  id: z.string(),
  ac: z.string(), // acceptance criterion label, e.g. "AC 1 — debounce dispara 1 request"
  kind: z.enum(["image", "video"]),
  name: z.string(),
  url: z.string(),
});

export const Agent = z.object({
  status: AgentStatus,
  turn: z.number().int().nullable(),
  maxTurns: z.number().int().nullable(),
  costUsd: z.number().nullable(),
  lastAction: z.string().nullable(),
});

export const Pr = z.object({
  number: z.number().int(),
  ci: CiStatus.nullable(),
  url: z.string().url().nullable(), // GitHub PR link
});

export const TimelineStep = z.object({
  label: z.string(),
  turn: z.number().int().nullable(),
  status: z.enum(["done", "active"]),
});

export const Ticket = z.object({
  id: z.string(), // "SODEV-956"
  title: z.string(),
  state: z.string(), // raw Linear state name
  agent: Agent,
  pr: Pr.nullable(),
  evidence: z.array(Evidence),
  timeline: z.array(TimelineStep).optional(),
  url: z.string().url().nullable().optional(), // Linear issue link
  traceUrl: z.string().url().nullable().optional(), // Langfuse trace link
  updatedAt: z.string(),
});

/**
 * Tracker states, mirrored from the Elixir tracker config. The board columns
 * are derived from these, never hardcoded, so the cockpit works for any tenant.
 */
export const TrackerStates = z.object({
  active: z.array(z.string()),
  onComplete: z.string().nullable(),
  onExhaust: z.string().nullable(),
  onPromote: z.string().nullable(),
  onPrMerge: z.string().nullable(),
  onReject: z.string().nullable(),
  terminal: z.array(z.string()),
});

export const BoardPayload = z.object({
  states: TrackerStates,
  tickets: z.array(Ticket),
});

export type AgentStatus = z.infer<typeof AgentStatus>;
export type CiStatus = z.infer<typeof CiStatus>;
export type Evidence = z.infer<typeof Evidence>;
export type TimelineStep = z.infer<typeof TimelineStep>;
export type Ticket = z.infer<typeof Ticket>;
export type TrackerStates = z.infer<typeof TrackerStates>;
export type BoardPayload = z.infer<typeof BoardPayload>;
