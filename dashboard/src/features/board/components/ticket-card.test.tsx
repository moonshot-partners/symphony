import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { TicketCard } from "./ticket-card";
import { MOCK_BOARD } from "../fixtures";
import type { Ticket } from "../contract";

const byId = (id: string): Ticket => MOCK_BOARD.tickets.find((t) => t.id === id)!;

describe("TicketCard", () => {
  it("shows plain working status, progress and proof for a running ticket", () => {
    render(<TicketCard ticket={byId("SODEV-956")} onSelect={() => {}} />);
    expect(screen.getByText("SODEV-956")).toBeInTheDocument();
    expect(screen.getByText("Fix collection search debounce")).toBeInTheDocument();
    expect(screen.getByText("Working")).toBeInTheDocument();
    expect(screen.getByText(/Proof \(4\)/)).toBeInTheDocument();
    expect(screen.getByRole("progressbar")).toBeInTheDocument();
  });

  it("hides raw agent mechanics (no turn count, no PR number)", () => {
    render(<TicketCard ticket={byId("SODEV-956")} onSelect={() => {}} />);
    expect(screen.queryByText(/turn/i)).toBeNull();
    expect(screen.queryByText(/PR #/)).toBeNull();
    expect(screen.queryByText(/lint/i)).toBeNull();
  });

  it("shows 'Checks passed' for a passing ticket and no Working badge", () => {
    render(<TicketCard ticket={byId("SODEV-940")} onSelect={() => {}} />);
    expect(screen.getByText("Checks passed")).toBeInTheDocument();
    expect(screen.queryByText("Working")).toBeNull();
    expect(screen.getByText(/Proof \(2\)/)).toBeInTheDocument();
  });

  it("calls onSelect with the ticket on click", () => {
    const onSelect = vi.fn();
    const ticket = byId("SODEV-964");
    render(<TicketCard ticket={ticket} onSelect={onSelect} />);
    fireEvent.click(screen.getByRole("button"));
    expect(onSelect).toHaveBeenCalledWith(ticket);
  });

  it("opens via keyboard with Enter", () => {
    const onSelect = vi.fn();
    const ticket = byId("SODEV-964");
    render(<TicketCard ticket={ticket} onSelect={onSelect} />);
    fireEvent.keyDown(screen.getByRole("button"), { key: "Enter" });
    expect(onSelect).toHaveBeenCalledWith(ticket);
  });
});
