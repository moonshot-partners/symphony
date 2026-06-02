import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { TicketDetail } from "./ticket-detail";
import { MOCK_BOARD } from "../fixtures";
import { MOCK_LIVE } from "@/features/live/fixtures";
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

  it("renders the QA report markdown table as real cells, not raw pipes", async () => {
    render(<TicketDetail ticket={running} onClose={() => {}} />);
    await screen.findByText("Timeline");
    expect(screen.getByText("QA report")).toBeInTheDocument();
    expect(screen.getByText("no loading flicker")).toBeInTheDocument();
    expect(screen.getByText("debounce fires one request")).toBeInTheDocument();
    // "PASS" appears once per table row (the bullet "Result: PASS" is a longer node)
    expect(screen.getAllByText("PASS")).toHaveLength(2);
  });

  it("renders the ticket description when present", async () => {
    render(<TicketDetail ticket={running} onClose={() => {}} />);
    await screen.findByText("Timeline");
    expect(screen.getByText("Description")).toBeInTheDocument();
    expect(screen.getByText(/Debounce it to 300ms/)).toBeInTheDocument();
  });

  it("renders the run summary markdown (heading, emphasis, inline code)", async () => {
    render(<TicketDetail ticket={running} onClose={() => {}} />);
    await screen.findByText("Timeline");
    expect(screen.getByText("Run summary")).toBeInTheDocument();
    // "## Ready for review" becomes a heading, not literal "##" text
    expect(screen.getByRole("heading", { name: "Ready for review" })).toBeInTheDocument();
    // "**Outcome:**" becomes bold
    expect(screen.getByText("Outcome:").tagName).toBe("STRONG");
    // "`In Code Review`" becomes inline code
    expect(screen.getByText("In Code Review").tagName).toBe("CODE");
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

  it("shows the live panel with turn, runtime and the pipeline rail for a running agent", async () => {
    render(
      <TicketDetail ticket={running} live={MOCK_LIVE.agents[0]} onClose={() => {}} />,
    );
    await screen.findByText("Timeline");

    expect(screen.getByRole("heading", { name: "Live" })).toBeInTheDocument();
    expect(screen.getByText(/turn 7/)).toBeInTheDocument();

    // The rail renders every lifecycle phase as an ordered step.
    const rail = screen.getByRole("list", { name: /pipeline position/i });
    expect(rail).toHaveTextContent("Working");
    expect(rail).toHaveTextContent("Done");

    // The live last action shows in the panel (also present as a timeline step).
    expect(screen.getAllByText("Running unit tests + lint").length).toBeGreaterThan(0);
  });

  it("deep links the Trace pill to the live trace while an agent is running", async () => {
    render(<TicketDetail ticket={running} live={MOCK_LIVE.agents[0]} onClose={() => {}} />);
    await screen.findByRole("heading", { name: "Live" });

    // The live trace (in flight) wins over the ticket's ledger trace.
    expect(MOCK_LIVE.agents[0].traceUrl).not.toBe(running.traceUrl);
    expect(screen.getByRole("link", { name: /trace/i })).toHaveAttribute(
      "href",
      MOCK_LIVE.agents[0].traceUrl!,
    );
  });

  it("shows the live cost in the live panel", async () => {
    render(<TicketDetail ticket={running} live={MOCK_LIVE.agents[0]} onClose={() => {}} />);
    await screen.findByRole("heading", { name: "Live" });
    expect(screen.getByText(/\$0\.42/)).toBeInTheDocument();
  });

  it("omits the live panel when no agent is running", async () => {
    render(<TicketDetail ticket={running} onClose={() => {}} />);
    await screen.findByText("Timeline");
    expect(screen.queryByRole("heading", { name: "Live" })).toBeNull();
  });

  it("hides the empty ledger Timeline and Evidence while an agent is running", async () => {
    const bare: Ticket = { ...running, timeline: [], evidence: [], summary: null, report: null };
    render(<TicketDetail ticket={bare} live={MOCK_LIVE.agents[0]} onClose={() => {}} />);
    await screen.findByRole("heading", { name: "Live" });

    expect(screen.queryByText("Timeline")).toBeNull();
    expect(screen.queryByText(/Evidence \(/)).toBeNull();
    expect(screen.queryByText("No activity yet.")).toBeNull();
  });

  it("still shows the empty Timeline and Evidence for an idle ticket", async () => {
    const bare: Ticket = { ...running, timeline: [], evidence: [], summary: null, report: null };
    render(<TicketDetail ticket={bare} onClose={() => {}} />);
    await screen.findByText("Timeline");

    expect(screen.getByText("No activity yet.")).toBeInTheDocument();
    expect(screen.getByText("No evidence captured.")).toBeInTheDocument();
  });
});
