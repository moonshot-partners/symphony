import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { AgentTimeline } from "./agent-timeline";
import { MOCK_LIVE } from "../fixtures";

describe("AgentTimeline", () => {
  it("renders the fixed e2e agent pipeline", () => {
    render(<AgentTimeline live={MOCK_LIVE.agents[0]} />);
    expect(screen.getAllByText("Start").length).toBeGreaterThan(0);
    expect(screen.getAllByText("Plan").length).toBeGreaterThan(0);
    expect(screen.getAllByText("Build").length).toBeGreaterThan(0);
    expect(screen.getAllByText("Verify").length).toBeGreaterThan(0);
    expect(screen.getAllByText("Review").length).toBeGreaterThan(0);
    expect(screen.getAllByText("Handoff").length).toBeGreaterThan(0);
  });

  it("marks the verify step as current when the agent is running checks", () => {
    render(<AgentTimeline live={MOCK_LIVE.agents[0]} />);
    expect(screen.getAllByText("current").length).toBeGreaterThan(0);
    expect(screen.getAllByText("Run checks and capture proof").length).toBeGreaterThan(0);
  });

  it("labels the mobile trigger with the fixed workflow count", () => {
    render(<AgentTimeline live={MOCK_LIVE.agents[0]} />);
    expect(screen.getByRole("button", { name: "6 workflow steps" })).toBeInTheDocument();
  });

  it("moves editing work to the build step", () => {
    render(<AgentTimeline live={{ ...MOCK_LIVE.agents[0], phase: "building", lastAction: "Editing search-input.tsx", lastEvent: "approval_auto_approved" }} />);
    expect(screen.getAllByText("Edit code and address the request").length).toBeGreaterThan(0);
  });

  it("can render the pipeline as completed after the live snapshot is gone", () => {
    render(<AgentTimeline live={{ phase: "handoff" }} completed />);
    expect(screen.getAllByText("done").length).toBeGreaterThanOrEqual(6);
    expect(screen.queryByText("current")).toBeNull();
  });
});
