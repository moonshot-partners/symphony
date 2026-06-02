import type { Ticket } from "./contract";

/**
 * Client-side ticket search. The board already holds every ticket in memory, so
 * finding a specific one is a pure filter over what's loaded, not a new fetch.
 * Matching is case-insensitive substring across the fields an operator searches
 * by: the id (so "956" finds "SODEV-956"), the title, and the raw state name.
 * Keeping this pure makes it trivial to test and reuse from the search bar.
 */

const normalize = (s: string): string => s.trim().toLowerCase();

/** Whether a ticket matches the query. An empty/whitespace query matches all. */
export function matchesTicket(ticket: Ticket, query: string): boolean {
  const q = normalize(query);
  if (q === "") return true;
  return (
    ticket.id.toLowerCase().includes(q) ||
    ticket.title.toLowerCase().includes(q) ||
    ticket.state.toLowerCase().includes(q)
  );
}

/**
 * Filter tickets by the query, preserving order. An empty/whitespace query
 * returns the same array reference so callers can skip re-render work cheaply.
 */
export function filterTickets(tickets: Ticket[], query: string): Ticket[] {
  if (normalize(query) === "") return tickets;
  return tickets.filter((t) => matchesTicket(t, query));
}
