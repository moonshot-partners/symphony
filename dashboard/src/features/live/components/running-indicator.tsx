"use client";

import { LoaderCircle } from "lucide-react";
import { useLive } from "../use-live";

/**
 * Header count of agents running right now. This is the headline the board (and
 * Linear) cannot show: how many agents are working this instant. Hidden when
 * none are running so the header stays quiet.
 */
export function RunningIndicator() {
  const { data } = useLive();
  const count = data?.agents.length ?? 0;
  if (count === 0) return null;

  return (
    <div className="flex items-center gap-1.5 text-xs font-medium text-emerald-700">
      <LoaderCircle className="size-3.5 animate-spin" aria-hidden />
      {count} working
    </div>
  );
}
