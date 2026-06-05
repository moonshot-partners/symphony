import { LivePayload } from "./contract";
import { MOCK_LIVE } from "./fixtures";

/**
 * Swappable data source, same shape as the board source. Production defaults
 * to `http` so live status follows Symphony as the source of truth. Tests and
 * local dev can still opt into fixtures with `NEXT_PUBLIC_DATA_SOURCE=mock`.
 */
const MODE =
  process.env.NEXT_PUBLIC_DATA_SOURCE ?? (process.env.NODE_ENV === "production" ? "http" : "mock");

const traceByAgentId = new Map<string, { sessionId: string; traceUrl: string }>();

export async function fetchLive(): Promise<LivePayload> {
  if (MODE === "http") {
    const res = await fetch("/api/live", { cache: "no-store" });
    if (!res.ok) throw new Error(`live fetch failed: ${res.status}`);
    return latchLiveTraceUrls(LivePayload.parse(await res.json()));
  }
  return latchLiveTraceUrls(LivePayload.parse(MOCK_LIVE));
}

export function latchLiveTraceUrls(payload: LivePayload): LivePayload {
  const liveIds = new Set(payload.agents.map((agent) => agent.id));

  for (const id of traceByAgentId.keys()) {
    if (!liveIds.has(id)) {
      traceByAgentId.delete(id);
    }
  }

  return {
    ...payload,
    agents: payload.agents.map((agent) => {
      if (agent.traceUrl) {
        if (agent.sessionId) {
          traceByAgentId.set(agent.id, { sessionId: agent.sessionId, traceUrl: agent.traceUrl });
        } else {
          traceByAgentId.delete(agent.id);
        }
        return agent;
      }

      const cached = traceByAgentId.get(agent.id);
      if (!agent.sessionId || !cached || cached.sessionId !== agent.sessionId) {
        return agent;
      }

      return { ...agent, traceUrl: cached.traceUrl };
    }),
  };
}
