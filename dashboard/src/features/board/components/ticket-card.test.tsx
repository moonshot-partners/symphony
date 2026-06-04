import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { TicketCard } from "./ticket-card";
import { MOCK_BOARD } from "../fixtures";
import { MOCK_LIVE } from "@/features/live/fixtures";
import type { Ticket } from "../contract";

const byId = (id: string): Ticket => MOCK_BOARD.tickets.find((t) => t.id === id)!;

const renderCard = (id: string, onSelect: (t: Ticket) => void = () => {}) =>
  render(<TicketCard ticket={byId(id)} states={MOCK_BOARD.states} onSelect={onSelect} />);

describe("TicketCard", () => {
  it("shows plain working status, progress and proof for a running ticket", () => {
    renderCard("SODEV-956");
    expect(screen.getByText("SODEV-956")).toBeInTheDocument();
    expect(screen.getByText("Fix collection search debounce")).toBeInTheDocument();
    expect(screen.getByText("Working")).toBeInTheDocument();
    expect(screen.getByText(/Proof \(4\)/)).toBeInTheDocument();
    expect(screen.getByRole("progressbar")).toBeInTheDocument();
  });

  it("hides raw agent mechanics (no turn count, no PR number)", () => {
    renderCard("SODEV-956");
    expect(screen.queryByText(/turn/i)).toBeNull();
    expect(screen.queryByText(/PR #/)).toBeNull();
    expect(screen.queryByText(/lint/i)).toBeNull();
  });

  it("appends the live runtime to the Working badge, staying plain (no action text)", () => {
    render(
      <TicketCard
        ticket={byId("SODEV-956")}
        states={MOCK_BOARD.states}
        live={MOCK_LIVE.agents[0]}
        onSelect={() => {}}
      />,
    );
    expect(screen.getByText(/Working · 2m/)).toBeInTheDocument();
    // the technical last action stays in the detail, not on the calm card
    expect(screen.queryByText(/lint/i)).toBeNull();
  });

  it("shows 'Checks passed' for a passing ticket and no Working badge", () => {
    renderCard("SODEV-940");
    expect(screen.getByText("Checks passed")).toBeInTheDocument();
    expect(screen.queryByText("Working")).toBeNull();
    expect(screen.getByText(/Proof \(2\)/)).toBeInTheDocument();
  });

  it("surfaces the raw tracker state on an idle card so states sharing a column are told apart", () => {
    renderCard("SODEV-940");
    expect(screen.getByText("In Code Review")).toBeInTheDocument();
  });

  it("hides the raw state while the agent is running (the Working badge already covers it)", () => {
    renderCard("SODEV-956");
    expect(screen.queryByText("In Progress")).toBeNull();
    expect(screen.getByText("Working")).toBeInTheDocument();
  });

  it("strikes through a killed terminal state (Cancelled) to set it apart from a real Done", () => {
    renderCard("SODEV-700");
    const pill = screen.getByText("Cancelled");
    expect(pill).toBeInTheDocument();
    expect(pill).toHaveClass("line-through");
  });

  it("does not strike through a successful done-extra state (Approved QA)", () => {
    renderCard("SODEV-880");
    const pill = screen.getByText("Approved QA");
    expect(pill).toBeInTheDocument();
    expect(pill).not.toHaveClass("line-through");
  });

  it("calls onSelect with the ticket on click", () => {
    const onSelect = vi.fn();
    const ticket = byId("SODEV-964");
    renderCard("SODEV-964", onSelect);
    fireEvent.click(screen.getByRole("button"));
    expect(onSelect).toHaveBeenCalledWith(ticket);
  });

  it("uses a native button for keyboard activation semantics", () => {
    renderCard("SODEV-964");
    expect(screen.getByRole("button").tagName).toBe("BUTTON");
  });
});
