import { describe, it, expect } from "vitest";
import { liveById } from "./merge";
import { MOCK_LIVE } from "./fixtures";
import type { LivePayload } from "./contract";

describe("liveById", () => {
  it("indexes agents by ticket id", () => {
    const map = liveById(MOCK_LIVE);
    expect(map.get("SODEV-956")?.turn).toBe(7);
    expect(map.size).toBe(MOCK_LIVE.agents.length);
  });

  it("returns an empty map for undefined input", () => {
    expect(liveById(undefined).size).toBe(0);
  });

  it("returns an empty map when no agents are running", () => {
    const empty: LivePayload = { available: true, agents: [], retrying: [], polling: null };
    expect(liveById(empty).size).toBe(0);
  });

  it("keeps the last agent when ids collide", () => {
    const dup: LivePayload = {
      available: true,
      agents: [
        { ...MOCK_LIVE.agents[0], turn: 1 },
        { ...MOCK_LIVE.agents[0], turn: 2 },
      ],
      retrying: [],
      polling: null,
    };
    expect(liveById(dup).get("SODEV-956")?.turn).toBe(2);
  });
});
