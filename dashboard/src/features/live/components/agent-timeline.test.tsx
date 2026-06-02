import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { AgentTimeline } from "./agent-timeline";
import { MOCK_LIVE } from "../fixtures";

describe("AgentTimeline", () => {
  it("renders a row per event with its action text", () => {
    render(<AgentTimeline events={MOCK_LIVE.agents[0].events} />);
    expect(screen.getByText("Running unit tests + lint")).toBeInTheDocument();
    expect(screen.getByText("Editing search-input.tsx")).toBeInTheDocument();
    expect(screen.getByText("Adding a 300ms debounce to the search handler")).toBeInTheDocument();
  });

  it("labels the trigger with the event count", () => {
    render(<AgentTimeline events={MOCK_LIVE.agents[0].events} />);
    expect(screen.getByText(/Recent activity \(4\)/)).toBeInTheDocument();
  });

  it("renders nothing when there are no events", () => {
    const { container } = render(<AgentTimeline events={[]} />);
    expect(container).toBeEmptyDOMElement();
  });

  it("falls back to the event tag when an action is null", () => {
    render(<AgentTimeline events={[{ event: "session_started", action: null, at: null }]} />);
    expect(screen.getByText("session_started")).toBeInTheDocument();
  });
});
