import { describe, it, expect } from "vitest";
import { BoardPayload, type Ticket } from "./contract";
import { MOCK_BOARD } from "./fixtures";
import { bucketTickets, columnFor, stateBadge, type ColumnKey } from "./bucket";

const idle: Ticket["agent"] = {
  status: "idle",
  turn: null,
  maxTurns: null,
  costUsd: null,
  lastAction: null,
};

function ticket(id: string, state: string, agent = idle): Ticket {
  return { id, title: id, state, agent, pr: null, evidence: [], updatedAt: "2026-05-30T00:00:00Z" };
}

describe("contract", () => {
  it("accepts the mock payload", () => {
    expect(() => BoardPayload.parse(MOCK_BOARD)).not.toThrow();
  });

  it("rejects a payload missing a required field", () => {
    const bad = { ...MOCK_BOARD, tickets: [{ id: "X" }] };
    expect(() => BoardPayload.parse(bad)).toThrow();
  });
});

describe("columnFor", () => {
  const states = MOCK_BOARD.states;

  it("maps each Linear state to its column", () => {
    const cases: Array<[string, ColumnKey]> = [
      ["Todo", "queued"],
      ["In Progress", "queued"],
      ["In Code Review", "review"],
      ["Promote to Staging", "staging"],
      ["Merged", "staging"],
      ["On Hold", "blocked"],
      ["Done", "done"],
      ["Cancelled", "done"],
      ["Backlog", "queued"],
      ["Groomed", "queued"],
      ["Approved QA", "done"],
      ["Recently released", "done"],
      ["In Development", "running"],
    ];
    for (const [state, col] of cases) {
      expect(columnFor(ticket("T", state), states)).toBe(col);
    }
  });

  it("running agent overrides the ticket state", () => {
    const running: Ticket["agent"] = { ...idle, status: "running", turn: 2, maxTurns: 20 };
    expect(columnFor(ticket("T", "In Code Review", running), states)).toBe("running");
  });

  it("falls back to queued for an unknown state", () => {
    expect(columnFor(ticket("T", "Some Weird State"), states)).toBe("queued");
  });
});

describe("bucketTickets", () => {
  it("places every mock ticket in the expected column", () => {
    const cols = bucketTickets(MOCK_BOARD);
    expect(cols.queued.map((t) => t.id)).toEqual(["SODEV-964"]);
    expect(cols.running.map((t) => t.id)).toEqual(["SODEV-956"]);
    expect(cols.review.map((t) => t.id)).toEqual(["SODEV-940"]);
    expect(cols.staging.map((t) => t.id)).toEqual(["SODEV-933"]);
    expect(cols.blocked.map((t) => t.id)).toEqual(["SODEV-430"]);
    expect(cols.done.map((t) => t.id)).toEqual(["SODEV-901", "SODEV-700", "SODEV-880"]);
  });

  it("covers every ticket exactly once", () => {
    const cols = bucketTickets(MOCK_BOARD);
    const total = Object.values(cols).reduce((n, ts) => n + ts.length, 0);
    expect(total).toBe(MOCK_BOARD.tickets.length);
  });
});

describe("stateBadge", () => {
  const states = MOCK_BOARD.states;

  it("tags a successful terminal state green", () => {
    expect(stateBadge(ticket("T", "Done"), states)).toEqual({ label: "Done", tone: "success" });
  });

  it("tags a done-extra state green", () => {
    expect(stateBadge(ticket("T", "Approved QA"), states)).toEqual({
      label: "Approved QA",
      tone: "success",
    });
  });

  it("tags a dropped terminal state (Cancelled / Duplicate) as killed", () => {
    expect(stateBadge(ticket("T", "Cancelled"), states)?.tone).toBe("killed");
    expect(stateBadge(ticket("T", "Duplicate"), states)?.tone).toBe("killed");
  });

  it("tags the reject state as needing attention", () => {
    expect(stateBadge(ticket("T", "On Hold"), states)?.tone).toBe("attention");
  });

  it("tags an in-flight state neutral", () => {
    expect(stateBadge(ticket("T", "Todo"), states)?.tone).toBe("neutral");
    expect(stateBadge(ticket("T", "In Code Review"), states)?.tone).toBe("neutral");
  });

  it("returns null while an agent is running (the Working badge covers it)", () => {
    const running: Ticket["agent"] = { ...idle, status: "running", turn: 2, maxTurns: 20 };
    expect(stateBadge(ticket("T", "In Progress", running), states)).toBeNull();
  });
});
