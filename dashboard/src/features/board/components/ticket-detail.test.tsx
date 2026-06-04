import { afterEach, describe, it, expect, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { TicketDetail } from "./ticket-detail";
import { MOCK_BOARD } from "../fixtures";
import { MOCK_LIVE } from "@/features/live/fixtures";
import type { Ticket } from "../contract";

const running: Ticket = MOCK_BOARD.tickets.find((t) => t.id === "SODEV-956")!;

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

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

  it("shows the live panel with turn, runtime and the fixed workflow for a running agent", async () => {
    render(
      <TicketDetail ticket={running} live={MOCK_LIVE.agents[0]} onClose={() => {}} />,
    );
    await screen.findByRole("heading", { name: "Agent workflow" });

    expect(screen.getByText("Live")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Agent workflow" })).toBeInTheDocument();
    expect(screen.getAllByText(/turn 7/i).length).toBeGreaterThan(0);

    // The live workflow is the fixed e2e pipeline, not the raw event stream.
    expect(screen.getAllByText("Build").length).toBeGreaterThan(0);
    expect(screen.getAllByText("Verify").length).toBeGreaterThan(0);
    expect(screen.getAllByText("Run checks and capture proof").length).toBeGreaterThan(0);

    // The live last action shows in the panel.
    expect(screen.getAllByText("Running unit tests + lint").length).toBeGreaterThan(0);
    expect(screen.queryByText("Timeline")).toBeNull();
  });

  it("deep links the Trace pill to the live trace while an agent is running", async () => {
    render(<TicketDetail ticket={running} live={MOCK_LIVE.agents[0]} onClose={() => {}} />);
    await screen.findByRole("heading", { name: "Agent workflow" });

    // The live trace (in flight) wins over the ticket's ledger trace.
    expect(MOCK_LIVE.agents[0].traceUrl).not.toBe(running.traceUrl);
    expect(screen.getByRole("link", { name: /trace/i })).toHaveAttribute(
      "href",
      MOCK_LIVE.agents[0].traceUrl!,
    );
  });

  it("shows one low-noise issue actions entry in the header", async () => {
    render(<TicketDetail ticket={running} onClose={() => {}} />);
    await screen.findByText("Timeline");

    expect(screen.getByRole("button", { name: /actions/i })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /reset plan/i })).toBeNull();
    expect(screen.queryByText(/symphony issue status/)).toBeNull();
  });

  it("opens issue actions with all operational choices", async () => {
    render(<TicketDetail ticket={running} onClose={() => {}} />);
    await screen.findByText("Timeline");

    fireEvent.click(screen.getByRole("button", { name: /actions/i }));

    expect(screen.getByRole("heading", { name: "Issue actions" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Inspect" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Safe actions" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Interrupt" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Destructive" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /status/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /audit/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /stop run/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /reset plan/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /run agent/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /rerun/i })).toBeInTheDocument();
  });

  it("resets the local plan pointers through the cockpit operation endpoint", async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ reset: true }) });
    vi.stubGlobal("fetch", fetchMock);
    const onActionComplete = vi.fn();
    render(<TicketDetail ticket={running} onClose={() => {}} onActionComplete={onActionComplete} />);
    await screen.findByText("Timeline");

    fireEvent.click(screen.getByRole("button", { name: /actions/i }));
    fireEvent.click(screen.getByRole("button", { name: /reset plan/i }));
    fireEvent.click(screen.getByRole("button", { name: "Reset plan" }));

    await waitFor(() =>
      expect(fetchMock).toHaveBeenCalledWith(
        "/api/operations/reset-plan",
        expect.objectContaining({
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ identifier: running.id }),
        })
      )
    );
    await waitFor(() => expect(onActionComplete).toHaveBeenCalled());
    expect(screen.getByText("Plan reset.")).toBeInTheDocument();
  });

  it("audits the issue through the cockpit operation endpoint", async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ identifier: running.id }) });
    vi.stubGlobal("fetch", fetchMock);
    render(<TicketDetail ticket={running} onClose={() => {}} />);
    await screen.findByText("Timeline");

    fireEvent.click(screen.getByRole("button", { name: /actions/i }));
    fireEvent.click(screen.getByRole("button", { name: /audit/i }));
    fireEvent.click(screen.getByRole("button", { name: "Run audit" }));

    await waitFor(() =>
      expect(fetchMock).toHaveBeenCalledWith(
        "/api/operations/audit",
        expect.objectContaining({
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ identifier: running.id }),
        })
      )
    );
    expect(screen.getByText("Audit complete.")).toBeInTheDocument();
  });

  it("enables stop run only when there is a live run", async () => {
    render(<TicketDetail ticket={running} live={MOCK_LIVE.agents[0]} onClose={() => {}} />);
    await screen.findByRole("heading", { name: "Agent workflow" });

    fireEvent.click(screen.getByRole("button", { name: /actions/i }));

    expect(screen.getByRole("heading", { name: "Interrupt" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /stop run/i })).toBeEnabled();
  });

  it("disables stop run when the issue is idle", async () => {
    render(<TicketDetail ticket={running} onClose={() => {}} />);
    await screen.findByText("Timeline");

    fireEvent.click(screen.getByRole("button", { name: /actions/i }));

    expect(screen.getByRole("button", { name: /stop run/i })).toBeDisabled();
    expect(screen.getByText("No active run to stop.")).toBeInTheDocument();
  });

  it("disables run agent while a live run exists but keeps destructive rerun available", async () => {
    render(<TicketDetail ticket={running} live={MOCK_LIVE.agents[0]} onClose={() => {}} />);
    await screen.findByRole("heading", { name: "Agent workflow" });

    fireEvent.click(screen.getByRole("button", { name: /actions/i }));

    expect(screen.getByRole("button", { name: /run agent/i })).toBeDisabled();
    expect(screen.getByText("Already running.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /rerun/i })).toBeEnabled();
  });

  it("opens status in a concise operational modal", async () => {
    render(<TicketDetail ticket={running} onClose={() => {}} />);
    await screen.findByText("Timeline");

    fireEvent.click(screen.getByRole("button", { name: /actions/i }));
    fireEvent.click(screen.getByRole("button", { name: /status/i }));

    expect(screen.getByRole("heading", { name: "Status" })).toBeInTheDocument();
    expect(screen.getByText("Refresh the verified state for this issue.")).toBeInTheDocument();
    expect(screen.getAllByText("Linear").length).toBeGreaterThan(0);
    expect(screen.getAllByText(running.state).length).toBeGreaterThan(0);
    expect(screen.getByRole("button", { name: "Refresh status" })).toBeEnabled();
    expect(screen.queryByText(/symphony issue status/)).toBeNull();
  });

  it("refreshes status through the cockpit operation endpoint", async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ queued: true }) });
    vi.stubGlobal("fetch", fetchMock);
    const onActionComplete = vi.fn();
    render(<TicketDetail ticket={running} onClose={() => {}} onActionComplete={onActionComplete} />);
    await screen.findByText("Timeline");

    fireEvent.click(screen.getByRole("button", { name: /actions/i }));
    fireEvent.click(screen.getByRole("button", { name: /status/i }));
    fireEvent.click(screen.getByRole("button", { name: "Refresh status" }));

    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith("/api/operations/refresh", { method: "POST" }));
    await waitFor(() => expect(onActionComplete).toHaveBeenCalled());
    expect(screen.getByText("Refresh queued.")).toBeInTheDocument();
  });

  it("stops the live run through the cockpit operation endpoint", async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ stopped: true }) });
    vi.stubGlobal("fetch", fetchMock);
    const onActionComplete = vi.fn();
    render(
      <TicketDetail
        ticket={running}
        live={MOCK_LIVE.agents[0]}
        onClose={() => {}}
        onActionComplete={onActionComplete}
      />
    );
    await screen.findByRole("heading", { name: "Agent workflow" });

    fireEvent.click(screen.getByRole("button", { name: /actions/i }));
    fireEvent.click(screen.getByRole("button", { name: /stop run/i }));

    expect(screen.getByRole("button", { name: "Stop run" })).toBeDisabled();
    fireEvent.click(screen.getByLabelText("I understand this terminates the active agent run."));
    fireEvent.click(screen.getByRole("button", { name: "Stop run" }));

    await waitFor(() =>
      expect(fetchMock).toHaveBeenCalledWith(
        "/api/operations/stop-run",
        expect.objectContaining({
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ issueId: MOCK_LIVE.agents[0].issueId }),
        })
      )
    );
    await waitFor(() => expect(onActionComplete).toHaveBeenCalled());
    expect(screen.getByText("Stop requested.")).toBeInTheDocument();
  });

  it("queues a new agent run through the cockpit operation endpoint", async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ queued: true }) });
    vi.stubGlobal("fetch", fetchMock);
    const onActionComplete = vi.fn();
    render(<TicketDetail ticket={running} onClose={() => {}} onActionComplete={onActionComplete} />);
    await screen.findByText("Timeline");

    fireEvent.click(screen.getByRole("button", { name: /actions/i }));
    fireEvent.click(screen.getByRole("button", { name: /run agent/i }));
    fireEvent.click(screen.getByRole("button", { name: "Run agent" }));

    await waitFor(() =>
      expect(fetchMock).toHaveBeenCalledWith(
        "/api/operations/run-agent",
        expect.objectContaining({
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ identifier: running.id }),
        })
      )
    );
    await waitFor(() => expect(onActionComplete).toHaveBeenCalled());
    expect(screen.getByText("Agent queued.")).toBeInTheDocument();
  });

  it("queues a rerun through the cockpit operation endpoint", async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ queued: true }) });
    vi.stubGlobal("fetch", fetchMock);
    const onClose = vi.fn();
    const onActionComplete = vi.fn();
    render(<TicketDetail ticket={running} onClose={onClose} onActionComplete={onActionComplete} />);
    await screen.findByText("Timeline");

    fireEvent.click(screen.getByRole("button", { name: /actions/i }));
    fireEvent.click(screen.getByRole("button", { name: /rerun/i }));

    expect(screen.getByRole("button", { name: "Rerun" })).toBeDisabled();
    fireEvent.click(screen.getByLabelText("I understand this deletes the Symphony workspace for this issue."));
    fireEvent.click(screen.getByRole("button", { name: "Rerun" }));

    await waitFor(() =>
      expect(fetchMock).toHaveBeenCalledWith(
        "/api/operations/rerun",
        expect.objectContaining({
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ identifier: running.id }),
        })
      )
    );
    await waitFor(() => expect(onActionComplete).toHaveBeenCalled());
    expect(onClose).toHaveBeenCalled();
    expect(screen.queryByText("Rerun queued.")).toBeNull();
  });

  it("keeps technical cost out of the nontechnical live panel", async () => {
    render(<TicketDetail ticket={running} live={MOCK_LIVE.agents[0]} onClose={() => {}} />);
    await screen.findByRole("heading", { name: "Agent workflow" });
    expect(screen.queryByText(/\$0\.42/)).toBeNull();
  });

  it("omits the live panel when no agent is running", async () => {
    render(<TicketDetail ticket={running} onClose={() => {}} />);
    await screen.findByText("Timeline");
    expect(screen.queryByRole("heading", { name: /Agent workflow/ })).toBeNull();
  });

  it("hides the ledger Timeline and empty Evidence while an agent is running", async () => {
    const bare: Ticket = { ...running, timeline: [], evidence: [], summary: null, report: null };
    render(<TicketDetail ticket={bare} live={MOCK_LIVE.agents[0]} onClose={() => {}} />);
    await screen.findByRole("heading", { name: "Agent workflow" });

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
