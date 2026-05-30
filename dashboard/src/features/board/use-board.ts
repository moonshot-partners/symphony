"use client";

import { useQuery } from "@tanstack/react-query";
import { fetchBoard } from "./source";

/**
 * Liveness via polling, not WebSocket. A board tolerates 1-2s lag, and polling
 * a JSON endpoint is the most boring, debuggable option.
 */
export function useBoard() {
  return useQuery({
    queryKey: ["board"],
    queryFn: fetchBoard,
    refetchInterval: 1500,
  });
}
