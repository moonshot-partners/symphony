import { Check, CircleAlert, Clock, LoaderCircle, Paperclip } from "lucide-react";
import type { CiStatus, Ticket, TrackerStates } from "../contract";
import type { LiveAgent } from "@/features/live/contract";
import { stateBadge, type StateTone } from "../bucket";
import { formatDuration } from "../time";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Progress } from "@/components/ui/progress";
import { StatusBadge, type StatusTone } from "@/components/status-badge";

/**
 * Plain-language card for a non-technical audience. The glance shows outcomes,
 * not agent mechanics: no turn counts, PR numbers, CI jargon, or cost. The raw
 * technical detail lives in the ticket detail for the operator.
 */
export function TicketCard({
  ticket,
  states,
  live,
  onSelect,
}: {
  ticket: Ticket;
  states: TrackerStates;
  live?: LiveAgent;
  onSelect: (ticket: Ticket) => void;
}) {
  const { agent, pr } = ticket;
  const running = agent.status === "running";
  const badge = stateBadge(ticket, states);
  const progressTurn = live?.turn ?? agent.turn;
  const progressMaxTurns = agent.maxTurns ?? 20;
  const pct =
    progressTurn != null && progressMaxTurns > 0
      ? Math.min(100, Math.round((progressTurn / progressMaxTurns) * 100))
      : 0;
  const proof = ticket.evidence.length;

  const open = () => onSelect(ticket);

  return (
    <button
      type="button"
      onClick={open}
      className="block w-full cursor-pointer appearance-none rounded-xl border-0 bg-transparent p-0 text-left outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background"
    >
      <Card
        size="sm"
        className="gap-2.5 transition-shadow hover:ring-foreground/20 hover:shadow-sm"
      >
        <CardHeader className="gap-1.5">
          <div className="flex items-center justify-between gap-2">
            <span className="font-mono text-xs text-muted-foreground">{ticket.id}</span>
            {running ? (
              <StatusBadge tone="success">
                <LoaderCircle className="animate-spin" aria-hidden />
                Working
                {live?.runtimeSeconds != null && ` · ${formatDuration(live.runtimeSeconds)}`}
              </StatusBadge>
            ) : (
              badge && <StatePill label={badge.label} tone={badge.tone} />
            )}
          </div>
          <CardTitle className="text-sm">{ticket.title}</CardTitle>
        </CardHeader>

        <CardContent className="flex flex-col gap-2">
          {running && (
            <div className="progress-sheen overflow-hidden rounded-full">
              <Progress value={pct} aria-label="Working on it" className="h-1.5" />
            </div>
          )}

          {(pr?.ci || proof > 0) && (
            <div className="flex flex-wrap items-center gap-1.5">
              {pr?.ci && <CheckBadge status={pr.ci} />}
              {proof > 0 && (
                <StatusBadge tone="muted" className="font-normal">
                  <Paperclip aria-hidden />
                  Proof ({proof})
                </StatusBadge>
              )}
            </div>
          )}
        </CardContent>
      </Card>
    </button>
  );
}

// One soft hue per lifecycle phase, matched to each column's header colour so
// the board reads as a calm, coherent colour map rather than a grey wall: zinc
// for waiting, emerald for in progress, blue for review, violet for staging,
// amber for attention, emerald for done. Tints stay light (bg-50) to keep the
// signal quiet. Killed states recede in struck-through grey so a dropped ticket
// never reads like the delivered ones beside it.
const TONE: Record<StateTone, StatusTone> = {
  queued: "neutral",
  running: "success",
  review: "info",
  staging: "accent",
  blocked: "warning",
  done: "success",
  killed: "muted",
};

function StatePill({ label, tone }: { label: string; tone: StateTone }) {
  return (
    <StatusBadge
      tone={TONE[tone]}
      className={tone === "killed" ? "min-w-0 max-w-[62%] shrink truncate font-normal line-through decoration-muted-foreground/40" : "min-w-0 max-w-[62%] shrink truncate font-normal"}
    >
      {label}
    </StatusBadge>
  );
}

function CheckBadge({ status }: { status: CiStatus }) {
  if (status === "failing")
    return (
      <StatusBadge tone="danger">
        <CircleAlert aria-hidden />
        Problem found
      </StatusBadge>
    );
  if (status === "passing")
    return (
      <StatusBadge tone="success">
        <Check aria-hidden />
        Checks passed
      </StatusBadge>
    );
  return (
    <StatusBadge tone="warning">
      <Clock aria-hidden />
      Checking<span className="loading-dots" aria-hidden />
    </StatusBadge>
  );
}
