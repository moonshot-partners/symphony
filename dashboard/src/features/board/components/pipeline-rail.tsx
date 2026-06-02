import { Check, LoaderCircle } from "lucide-react";
import type { ColumnKey } from "../bucket";

// The happy-path spine of the lifecycle. "blocked" is a side state, not a step,
// so it is not on the rail.
const RAIL: { key: Exclude<ColumnKey, "blocked">; label: string }[] = [
  { key: "queued", label: "Queued" },
  { key: "running", label: "Working" },
  { key: "review", label: "Review" },
  { key: "staging", label: "Staging" },
  { key: "done", label: "Done" },
];

/**
 * Horizontal lifecycle rail showing where the agent is in the pipeline. The
 * caller passes the current phase (a running agent is in "running"). Steps
 * before it read as done, the current one pulses, later ones are muted.
 */
export function PipelineRail({ current }: { current: ColumnKey }) {
  const activeIndex = RAIL.findIndex((p) => p.key === current);

  return (
    <ol className="flex items-center gap-1" aria-label="Pipeline position">
      {RAIL.map((phase, i) => {
        const done = activeIndex >= 0 && i < activeIndex;
        const active = i === activeIndex;
        return (
          <li key={phase.key} className="flex flex-1 items-center gap-1">
            <span
              className={`flex items-center gap-1 text-xs ${
                active
                  ? "font-medium text-emerald-700"
                  : done
                    ? "text-muted-foreground"
                    : "text-muted-foreground/50"
              }`}
            >
              {active ? (
                <LoaderCircle className="size-3 animate-spin" aria-hidden />
              ) : done ? (
                <Check className="size-3" aria-hidden />
              ) : (
                <span className="size-1.5 rounded-full bg-current" aria-hidden />
              )}
              {phase.label}
            </span>
            {i < RAIL.length - 1 && (
              <span
                className={`h-px flex-1 ${done ? "bg-muted-foreground/30" : "bg-border"}`}
                aria-hidden
              />
            )}
          </li>
        );
      })}
    </ol>
  );
}
