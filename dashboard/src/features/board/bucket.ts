import type { BoardPayload, Ticket, TrackerStates } from "./contract";

/**
 * The lifecycle columns. Order matters: a running agent overrides the ticket's
 * Linear state, so "running" is evaluated before the state-based buckets.
 */
export const COLUMNS = [
  { key: "queued", label: "Up next" },
  { key: "running", label: "In progress" },
  { key: "review", label: "Being reviewed" },
  { key: "staging", label: "Ready to ship" },
  { key: "blocked", label: "Needs attention" },
  { key: "done", label: "Done" },
] as const;

export type ColumnKey = (typeof COLUMNS)[number]["key"];

/** Map one ticket to a column, deriving the bucket from the tracker config. */
export function columnFor(ticket: Ticket, states: TrackerStates): ColumnKey {
  if (ticket.agent.status === "running") return "running";

  const s = ticket.state;
  if (states.terminal.includes(s) || (states.doneExtra ?? []).includes(s)) return "done";
  if (s === states.onReject) return "blocked";
  if (s === states.onPromote || s === states.onPrMerge) return "staging";
  if (s === states.onComplete || s === states.onExhaust) return "review";
  if (states.active.includes(s) || (states.upNextExtra ?? []).includes(s)) return "queued";
  return "queued"; // unknown state falls back to the entry column
}

/** Group every ticket into its column. Pure: same input -> same output. */
export function bucketTickets(payload: BoardPayload): Record<ColumnKey, Ticket[]> {
  const out = COLUMNS.reduce((acc, c) => {
    acc[c.key] = [];
    return acc;
  }, {} as Record<ColumnKey, Ticket[]>);
  for (const ticket of payload.tickets) {
    out[columnFor(ticket, payload.states)].push(ticket);
  }
  return out;
}
