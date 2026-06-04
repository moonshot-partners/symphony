"use client";

import { useQuery } from "@tanstack/react-query";
import { fetchLive } from "./source";

/**
 * Live agent telemetry via fast polling. Separate query from the board: the
 * board is slow, expensive, and cached 60s upstream, while this reads the
 * orchestrator's in-memory snapshot, which is cheap and changes every turn. A
 * shorter interval here keeps "what the agent is doing now" fresh without
 * making the board hammer Linear.
 */
export function useLive() {
  return useQuery({
    queryKey: ["live"],
    queryFn: fetchLive,
    refetchInterval: 2000,
  });
}
