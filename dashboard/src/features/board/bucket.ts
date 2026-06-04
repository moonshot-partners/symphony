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
  if ((states.inProgressExtra ?? []).includes(s)) return "running";
  if (states.terminal.includes(s) || (states.doneExtra ?? []).includes(s)) return "done";
  if (s === states.onReject) return "blocked";
  if (s === states.onPromote || s === states.onPrMerge) return "staging";
  if (s === states.onComplete || s === states.onExhaust) return "review";
  if (states.active.includes(s) || (states.upNextExtra ?? []).includes(s)) return "queued";
  return "queued"; // unknown state falls back to the entry column
}

/**
 * The tone of a card's state pill. It mirrors the lifecycle column, so each
 * phase carries one consistent hue (waiting, in progress, in review, staging,
 * attention, done) — the same colour the column header already uses. The lone
 * exception is `killed`: dropped terminals (Cancelled, Duplicate) share the Done
 * column with real successes, so they recede in muted grey instead of reading
 * green. Colour encodes the phase; the text label tells apart states that share
 * one column.
 */
export type StateTone = ColumnKey | "killed";

// Terminal states whose name signals the work was dropped, not delivered.
const KILLED = /cancel|duplicat|abandon|reject|won'?t/i;

/**
 * The raw tracker state to surface on a card, with a tone derived from the
 * lifecycle column. Returns null when the state is already obvious from another
 * cue: a running agent shows the "Working" badge, so its state is redundant.
 */
export function stateBadge(
  ticket: Ticket,
  states: TrackerStates,
): { label: string; tone: StateTone } | null {
  if (ticket.agent.status === "running") return null;

  const s = ticket.state;
  const col = columnFor(ticket, states);
  if (col === "done" && KILLED.test(s)) return { label: s, tone: "killed" };
  return { label: s, tone: col };
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
