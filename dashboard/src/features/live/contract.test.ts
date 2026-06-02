import { describe, it, expect } from "vitest";
import { LivePayload } from "./contract";
import { MOCK_LIVE } from "./fixtures";

describe("LivePayload contract", () => {
  it("accepts the mock snapshot", () => {
    expect(() => LivePayload.parse(MOCK_LIVE)).not.toThrow();
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
