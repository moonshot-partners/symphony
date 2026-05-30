"use client";

import { useEffect, useState } from "react";
import { useBoard } from "../use-board";
import { formatAgo } from "../time";

/**
 * Freshness indicator for the header. Shares the board query (same queryKey,
 * so no extra fetch) and shows when data last refreshed. The pinging dot keeps
 * a constant sense that the system is live.
 */
export function LiveStatus() {
  const { isPending, dataUpdatedAt } = useBoard();
  const [now, setNow] = useState<number | null>(null);

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);

  const label = isPending
    ? "connecting…"
    : now && dataUpdatedAt
      ? `live · updated ${formatAgo(now - dataUpdatedAt)}`
      : "live";

  return (
    <div className="flex items-center gap-2 text-xs text-muted-foreground">
      <span className="relative flex size-2">
        <span className="absolute inline-flex size-full animate-ping rounded-full bg-emerald-400 opacity-60" />
        <span className="relative inline-flex size-2 rounded-full bg-emerald-500" />
      </span>
      schools-out · {label}
    </div>
  );
}
