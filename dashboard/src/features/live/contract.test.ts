import { describe, it, expect } from "vitest";
import { LivePayload } from "./contract";
import { MOCK_LIVE } from "./fixtures";

describe("LivePayload contract", () => {
  it("accepts the mock snapshot", () => {
    expect(() => LivePayload.parse(MOCK_LIVE)).not.toThrow();
  });

  it("carries the live trace url and cost on the agent", () => {
    const agent = LivePayload.parse(MOCK_LIVE).agents[0];
    expect(agent.phase).toBe("verifying");
    expect(agent.traceUrl).toBe("https://cloud.langfuse.com/trace/live-trace-956");
    expect(agent.costUsd).toBe(0.42);
  });

  it("accepts a null trace url and null cost (before the agent's first update)", () => {
    const fresh = {
      ...MOCK_LIVE,
      agents: [{ ...MOCK_LIVE.agents[0], traceUrl: null, costUsd: null }],
    };
    expect(() => LivePayload.parse(fresh)).not.toThrow();
  });

  it("parses the agent's activity timeline", () => {
    const agent = LivePayload.parse(MOCK_LIVE).agents[0];
    expect(agent.events).toHaveLength(4);
    expect(agent.events[0].action).toBe("Running unit tests + lint");
  });

  it("defaults events to an empty array when the field is absent", () => {
    const noEvents = { ...MOCK_LIVE.agents[0] } as Record<string, unknown>;
    delete noEvents.events;
    const payload = { ...MOCK_LIVE, agents: [noEvents] };
    expect(LivePayload.parse(payload).agents[0].events).toEqual([]);
  });

  it("accepts the unavailable shape (orchestrator unreachable)", () => {
    const unavailable = { available: false, agents: [], retrying: [], polling: null };
    expect(() => LivePayload.parse(unavailable)).not.toThrow();
  });

  it("rejects an agent missing required fields", () => {
    const bad = { ...MOCK_LIVE, agents: [{ id: "X" }] };
    expect(() => LivePayload.parse(bad)).toThrow();
  });

  it("rejects a non-boolean availability flag", () => {
    expect(() => LivePayload.parse({ ...MOCK_LIVE, available: "yes" })).toThrow();
  });
});
