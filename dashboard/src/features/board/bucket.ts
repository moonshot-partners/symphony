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
 * The tone of a card's state pill. A column groups several raw tracker states
 * (e.g. Done holds Done, Cancelled, Approved QA), so the pill's tone is what
 * tells them apart at a glance: a finished win reads differently from a kill.
 */
export type StateTone = "success" | "killed" | "attention" | "neutral";

// Terminal states whose name signals the work was dropped, not delivered. These
// share the Done column with genuine successes, so they get a muted, struck tone.
const KILLED = /cancel|duplicat|abandon|reject|won'?t/i;

/**
 * The raw tracker state to surface on a card, with a tone derived from the
 * tracker config. Returns null when the state is already obvious from another
 * cue: a running agent shows the "Working" badge, so its state is redundant.
 */
export function stateBadge(
  ticket: Ticket,
  states: TrackerStates,
): { label: string; tone: StateTone } | null {
  if (ticket.agent.status === "running") return null;

  const s = ticket.state;
  if (states.terminal.includes(s) || (states.doneExtra ?? []).includes(s)) {
    return { label: s, tone: KILLED.test(s) ? "killed" : "success" };
  }
  if (s === states.onReject) return { label: s, tone: "attention" };
  return { label: s, tone: "neutral" };
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
