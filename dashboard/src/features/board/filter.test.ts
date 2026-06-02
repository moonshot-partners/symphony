import { describe, it, expect } from "vitest";
import type { Ticket } from "./contract";
import { filterTickets, matchesTicket } from "./filter";

const idle: Ticket["agent"] = {
  status: "idle",
  turn: null,
  maxTurns: null,
  costUsd: null,
  lastAction: null,
};

function ticket(id: string, title: string, state: string): Ticket {
  return { id, title, state, agent: idle, pr: null, evidence: [], updatedAt: "2026-05-30T00:00:00Z" };
}

const TICKETS: Ticket[] = [
  ticket("SODEV-964", "Add empty state to saved searches", "Todo"),
  ticket("SODEV-956", "Fix collection search debounce", "In Progress"),
  ticket("SODEV-940", "Vendor profile avatar upload", "In Code Review"),
  ticket("SODEV-933", "Search results pagination", "Promote to Staging"),
  ticket("SODEV-430", "Filter collections by neighborhood", "On Hold"),
];

const ids = (ts: Ticket[]) => ts.map((t) => t.id);

describe("matchesTicket", () => {
  const t = ticket("SODEV-940", "Vendor profile avatar upload", "In Code Review");

  it("matches a bare number against the ticket id", () => {
    expect(matchesTicket(t, "940")).toBe(true);
  });

  it("matches the full id case-insensitively", () => {
    expect(matchesTicket(t, "sodev-940")).toBe(true);
  });

  it("matches a title substring case-insensitively", () => {
    expect(matchesTicket(t, "AVATAR")).toBe(true);
  });

  it("matches the raw state name", () => {
    expect(matchesTicket(t, "code review")).toBe(true);
  });

  it("does not match an unrelated query", () => {
    expect(matchesTicket(t, "robots")).toBe(false);
  });

  it("treats an empty query as a match", () => {
    expect(matchesTicket(t, "")).toBe(true);
    expect(matchesTicket(t, "   ")).toBe(true);
  });
});

describe("filterTickets", () => {
  it("returns every ticket for an empty query", () => {
    expect(filterTickets(TICKETS, "")).toBe(TICKETS);
  });

  it("returns every ticket for a whitespace-only query", () => {
    expect(filterTickets(TICKETS, "   ")).toBe(TICKETS);
  });

  it("finds one ticket by number", () => {
    expect(ids(filterTickets(TICKETS, "956"))).toEqual(["SODEV-956"]);
  });

  it("finds tickets by a shared title word, case-insensitively", () => {
    expect(ids(filterTickets(TICKETS, "SEARCH"))).toEqual([
      "SODEV-964",
      "SODEV-956",
      "SODEV-933",
    ]);
  });

  it("finds tickets by state name", () => {
    expect(ids(filterTickets(TICKETS, "on hold"))).toEqual(["SODEV-430"]);
  });

  it("trims surrounding whitespace before matching", () => {
    expect(ids(filterTickets(TICKETS, "  940  "))).toEqual(["SODEV-940"]);
  });

  it("returns an empty list when nothing matches", () => {
    expect(filterTickets(TICKETS, "zzz")).toEqual([]);
  });

  it("preserves the original order of matches", () => {
    expect(ids(filterTickets(TICKETS, "sodev"))).toEqual(ids(TICKETS));
  });
});
