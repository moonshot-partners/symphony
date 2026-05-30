import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { TicketDetail } from "./ticket-detail";
import { MOCK_BOARD } from "../fixtures";
import type { Ticket } from "../contract";

const running: Ticket = MOCK_BOARD.tickets.find((t) => t.id === "SODEV-956")!;

describe("TicketDetail", () => {
  it("renders nothing when no ticket is selected", () => {
    render(<TicketDetail ticket={null} onClose={() => {}} />);
    expect(screen.queryByText("Timeline")).toBeNull();
  });

  it("shows the timeline and every evidence group expanded", async () => {
    render(<TicketDetail ticket={running} onClose={() => {}} />);
    expect(await screen.findByText("Timeline")).toBeInTheDocument();
    expect(screen.getByText("Running unit tests + lint")).toBeInTheDocument();
    // both AC groups and their items are visible (nothing collapsed)
    expect(screen.getByText(/AC 1 — debounce fires one request/)).toBeInTheDocument();
    expect(screen.getByText(/AC 2 — no loading flicker/)).toBeInTheDocument();
    expect(screen.getByText("before.png")).toBeInTheDocument();
    expect(screen.getByText("flicker-1.png")).toBeInTheDocument();
  });

  it("exposes Linear, GitHub PR and Langfuse trace as new-tab links", async () => {
    render(<TicketDetail ticket={running} onClose={() => {}} />);
    await screen.findByText("Timeline");

    const linear = screen.getByRole("link", { name: /linear/i });
    expect(linear).toHaveAttribute("href", running.url!);
    expect(linear).toHaveAttribute("target", "_blank");
    expect(linear.getAttribute("rel")).toContain("noopener");

    expect(screen.getByRole("link", { name: /pull request 642/i })).toHaveAttribute(
      "href",
      running.pr!.url!
    );
    expect(screen.getByRole("link", { name: /trace/i })).toHaveAttribute(
      "href",
      running.traceUrl!
    );
  });
});
