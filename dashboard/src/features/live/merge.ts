import type { LiveAgent, LivePayload } from "./contract";

/**
 * Index the live agents by ticket id so a board card or the detail can look up
 * its live overlay in O(1). Pure: same input -> same output. Returns an empty
 * map when there is no live data (mock-less dev, orchestrator unreachable), so
 * callers never special-case null.
 */
export function liveById(payload: LivePayload | undefined): Map<string, LiveAgent> {
  const map = new Map<string, LiveAgent>();
  if (!payload) return map;
  for (const agent of payload.agents) map.set(agent.id, agent);
  return map;
}
