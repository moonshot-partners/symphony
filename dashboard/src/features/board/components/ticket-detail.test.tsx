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

  it("shows the timeline and a flat evidence gallery", async () => {
    render(<TicketDetail ticket={running} onClose={() => {}} />);
    expect(await screen.findByText("Timeline")).toBeInTheDocument();
    expect(screen.getByText("Running unit tests + lint")).toBeInTheDocument();
    expect(screen.getByText(`Evidence (${running.evidence.length})`)).toBeInTheDocument();
    // every captured item is visible (no AC grouping, nothing collapsed)
    expect(screen.getByText("before.png")).toBeInTheDocument();
    expect(screen.getByText("flow.webm")).toBeInTheDocument();
    expect(screen.getByText("flicker-1.png")).toBeInTheDocument();
  });

  it("renders the QA report when present", async () => {
    render(<TicketDetail ticket={running} onClose={() => {}} />);
    await screen.findByText("Timeline");
    expect(screen.getByText("QA report")).toBeInTheDocument();
    expect(screen.getByText(/no loading flicker \| PASS/)).toBeInTheDocument();
  });

  it("renders the run summary when present", async () => {
    render(<TicketDetail ticket={running} onClose={() => {}} />);
    await screen.findByText("Timeline");
    expect(screen.getByText("Run summary")).toBeInTheDocument();
    expect(
      screen.getByText(/Moved to `In Code Review` after PR checks and Symphony gates passed/)
    ).toBeInTheDocument();
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
