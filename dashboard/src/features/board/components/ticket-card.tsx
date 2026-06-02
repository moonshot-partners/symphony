import { Check, CircleAlert, Clock, LoaderCircle, Paperclip } from "lucide-react";
import type { CiStatus, Ticket, TrackerStates } from "../contract";
import { stateBadge, type StateTone } from "../bucket";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Progress } from "@/components/ui/progress";

/**
 * Plain-language card for a non-technical audience. The glance shows outcomes,
 * not agent mechanics: no turn counts, PR numbers, CI jargon, or cost. The raw
 * technical detail lives in the ticket detail for the operator.
 */
export function TicketCard({
  ticket,
  states,
  onSelect,
}: {
  ticket: Ticket;
  states: TrackerStates;
  onSelect: (ticket: Ticket) => void;
}) {
  const { agent, pr } = ticket;
  const running = agent.status === "running";
  const badge = stateBadge(ticket, states);
  const pct =
    agent.turn && agent.maxTurns
      ? Math.min(100, Math.round((agent.turn / agent.maxTurns) * 100))
      : 0;
  const proof = ticket.evidence.length;

  const open = () => onSelect(ticket);

  return (
    <div
      role="button"
      tabIndex={0}
      onClick={open}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          open();
        }
      }}
      className="cursor-pointer rounded-xl outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background"
    >
      <Card
        size="sm"
        className="gap-2.5 transition-shadow hover:ring-foreground/20 hover:shadow-sm"
      >
        <CardHeader className="gap-1.5">
          <div className="flex items-center justify-between gap-2">
            <span className="font-mono text-xs text-muted-foreground">{ticket.id}</span>
            {running ? (
              <Badge
                variant="outline"
                className="border-emerald-200 bg-emerald-50 text-emerald-700"
              >
                <LoaderCircle className="animate-spin" aria-hidden />
                Working
              </Badge>
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
                <Badge variant="outline" className="font-normal text-muted-foreground">
                  <Paperclip aria-hidden />
                  Proof ({proof})
                </Badge>
              )}
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

// Tones tuned for visual silence: success/attention reuse the card's existing
// emerald/amber accents; killed is de-emphasized and struck through so a dropped
// ticket never reads like a delivered one; neutral is a quiet in-flight label.
const TONE: Record<StateTone, string> = {
  success: "border-emerald-200 bg-emerald-50 text-emerald-700",
  killed: "text-muted-foreground line-through decoration-muted-foreground/40",
  attention: "border-amber-200 bg-amber-50 text-amber-700",
  neutral: "text-muted-foreground",
};

function StatePill({ label, tone }: { label: string; tone: StateTone }) {
  return (
    <Badge variant="outline" className={`min-w-0 max-w-[62%] shrink truncate font-normal ${TONE[tone]}`}>
      {label}
    </Badge>
  );
}

function CheckBadge({ status }: { status: CiStatus }) {
  if (status === "failing")
    return (
      <Badge variant="destructive">
        <CircleAlert aria-hidden />
        Problem found
      </Badge>
    );
  if (status === "passing")
    return (
      <Badge variant="outline" className="border-emerald-200 bg-emerald-50 text-emerald-700">
        <Check aria-hidden />
        Checks passed
      </Badge>
    );
  return (
    <Badge variant="outline" className="border-amber-200 bg-amber-50 text-amber-700">
      <Clock aria-hidden />
      Checking<span className="loading-dots" aria-hidden />
    </Badge>
  );
}
