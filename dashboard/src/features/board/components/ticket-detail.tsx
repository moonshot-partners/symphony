"use client";

import type { Ticket } from "../contract";
import type { LiveAgent } from "@/features/live/contract";
import { formatDuration } from "../time";
import { AgentTimeline } from "@/features/live/components/agent-timeline";
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetDescription,
} from "@/components/ui/sheet";
import {
  Activity,
  Check,
  ExternalLink,
  GitPullRequest,
  LoaderCircle,
  type LucideIcon,
} from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Markdown } from "@/components/markdown";
import { Separator } from "@/components/ui/separator";
import {
  Attachment,
  AttachmentInfo,
  AttachmentPreview,
  Attachments,
  type AttachmentData,
} from "@/components/ai-elements/attachments";
import { Task, TaskContent, TaskItem, TaskTrigger } from "@/components/ai-elements/task";
import type { Evidence } from "../contract";

export function TicketDetail({
  ticket,
  live,
  onClose,
}: {
  ticket: Ticket | null;
  live?: LiveAgent;
  onClose: () => void;
}) {
  return (
    <Sheet open={!!ticket} onOpenChange={(open) => !open && onClose()}>
      <SheetContent
        side="right"
        style={{ width: "44rem", maxWidth: "94vw" }}
        className="gap-0"
      >
        {ticket && <Body ticket={ticket} live={live} />}
      </SheetContent>
    </Sheet>
  );
}

function Body({ ticket, live }: { ticket: Ticket; live?: LiveAgent }) {
  const { agent, pr } = ticket;
  const steps = ticket.timeline ?? [];
  // While an agent is running, the Live panel is the story; the ledger Timeline
  // and Evidence only fill in after the run finishes, so hide their empty
  // placeholders to keep a running ticket from reading as broken. Idle tickets
  // keep showing them (the ledger is their content, even when empty).
  const showTimeline = steps.length > 0 || !live;
  const showEvidence = ticket.evidence.length > 0 || !live;
  // While running, the in-flight live trace wins over the ticket's ledger trace
  // (which is the previous finished run, and so stale for a running agent).
  const traceUrl = live?.traceUrl ?? ticket.traceUrl;

  return (
    <>
      <SheetHeader className="gap-1.5">
        <span className="font-mono text-xs text-muted-foreground">{ticket.id}</span>
        <SheetTitle className="text-base">{ticket.title}</SheetTitle>
        <SheetDescription className="sr-only">Ticket detail</SheetDescription>
        <div className="mt-1 flex flex-wrap items-center gap-1.5">
          <Badge variant="secondary">{ticket.state}</Badge>
          {agent.costUsd != null && (
            <Badge variant="outline" className="font-mono text-muted-foreground">
              ${agent.costUsd.toFixed(2)}
            </Badge>
          )}
        </div>

        {(ticket.url || pr?.url || traceUrl) && (
          <div className="mt-2 flex flex-wrap items-center gap-2">
            {ticket.url && (
              <LinkPill href={ticket.url} icon={ExternalLink} label="Open this ticket in Linear">
                Linear
              </LinkPill>
            )}
            {pr?.url && (
              <LinkPill
                href={pr.url}
                icon={GitPullRequest}
                label={`Open pull request ${pr.number} on GitHub`}
              >
                PR #{pr.number}
              </LinkPill>
            )}
            {traceUrl && (
              <LinkPill href={traceUrl} icon={Activity} label="View this run's trace in Langfuse">
                Trace
              </LinkPill>
            )}
          </div>
        )}
      </SheetHeader>

      <Separator />

      <div className="flex-1 space-y-6 overflow-y-auto p-4">
        {live && (
          <section className="rounded-lg border border-emerald-200 bg-emerald-50/60 p-3">
            <div className="mb-3 flex items-center justify-between gap-2">
              <h3 className="text-xs font-medium uppercase tracking-wide text-emerald-700">Live</h3>
              <span className="flex items-center gap-1.5 font-mono text-xs text-emerald-700">
                <LoaderCircle className="size-3.5 animate-spin" aria-hidden />
                turn {live.turn ?? "—"} · {formatDuration(live.runtimeSeconds ?? 0)}
              </span>
            </div>
            {live.lastAction && <p className="mt-3 text-sm leading-snug">{live.lastAction}</p>}
            <AgentTimeline events={live.events} />
            <p className="mt-2 font-mono text-xs text-muted-foreground">
              {live.tokens.total.toLocaleString()} tokens
              {live.costUsd != null && ` · $${live.costUsd.toFixed(2)}`}
            </p>
          </section>
        )}

        {ticket.description && (
          <section>
            <SectionLabel>Description</SectionLabel>
            <Markdown>{ticket.description}</Markdown>
          </section>
        )}

        {(showTimeline || showEvidence) && (
        <div className="grid grid-cols-1 gap-6 md:grid-cols-2">
          {showTimeline && (
          <section>
            <SectionLabel>Timeline</SectionLabel>
            {steps.length === 0 ? (
              <p className="text-sm text-muted-foreground">No activity yet.</p>
            ) : (
              <Task defaultOpen>
                <TaskTrigger title={`${steps.length} ${steps.length === 1 ? "step" : "steps"}`} />
                <TaskContent>
                {steps.map((s, i) => (
                  <TaskItem key={i} className="flex items-start gap-2.5">
                    {s.status === "active" ? (
                      <LoaderCircle
                        className="mt-0.5 size-3.5 flex-none animate-spin text-emerald-600"
                        aria-hidden
                      />
                    ) : (
                      <Check className="mt-0.5 size-3.5 flex-none text-muted-foreground" aria-hidden />
                    )}
                    <div className="min-w-0">
                      <p className="text-sm leading-snug">{s.label}</p>
                      {s.turn != null && (
                        <p className="font-mono text-xs text-muted-foreground">turn {s.turn}</p>
                      )}
                    </div>
                  </TaskItem>
                ))}
                </TaskContent>
              </Task>
            )}
          </section>
          )}

          {showEvidence && (
          <section>
            <SectionLabel>Evidence ({ticket.evidence.length})</SectionLabel>
            {ticket.evidence.length === 0 ? (
              <p className="text-sm text-muted-foreground">No evidence captured.</p>
            ) : (
              <Attachments variant="list" className="w-full">
                {ticket.evidence.map((item) => (
                  <EvidenceThumb key={item.id} item={item} />
                ))}
              </Attachments>
            )}
          </section>
          )}
        </div>
        )}

        {ticket.summary && (
          <section>
            <SectionLabel>Run summary</SectionLabel>
            <Markdown>{ticket.summary}</Markdown>
          </section>
        )}

        {ticket.report && (
          <section>
            <SectionLabel>QA report</SectionLabel>
            <Markdown>{ticket.report}</Markdown>
          </section>
        )}
      </div>
    </>
  );
}

function SectionLabel({ children }: { children: React.ReactNode }) {
  return (
    <h3 className="mb-3 text-xs font-medium uppercase tracking-wide text-muted-foreground">
      {children}
    </h3>
  );
}

function LinkPill({
  href,
  icon: Icon,
  label,
  children,
}: {
  href: string;
  icon: LucideIcon;
  label: string;
  children: React.ReactNode;
}) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      aria-label={`${label} (opens in a new tab)`}
      className="inline-flex items-center gap-1.5 rounded-md border bg-background px-2 py-1 text-xs font-medium text-foreground transition-colors hover:bg-muted focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
    >
      <Icon className="size-3.5" aria-hidden />
      {children}
      <ExternalLink className="size-3 text-muted-foreground" aria-hidden />
    </a>
  );
}

function EvidenceThumb({ item }: { item: Evidence }) {
  const attachment = evidenceToAttachment(item);

  return (
    <a
      href={item.url}
      target="_blank"
      rel="noopener noreferrer"
      className="block w-full rounded-lg outline-none focus-visible:ring-2 focus-visible:ring-ring"
    >
      <Attachment data={attachment}>
        <AttachmentPreview />
        <AttachmentInfo showMediaType />
      </Attachment>
    </a>
  );
}

function evidenceToAttachment(item: Evidence): AttachmentData {
  return {
    id: item.id,
    type: "file",
    filename: item.name,
    mediaType: mediaTypeFor(item),
    url: item.url === "#" ? "" : item.url,
  };
}

function mediaTypeFor(item: Evidence): string {
  if (item.kind === "video") return item.name.endsWith(".mp4") ? "video/mp4" : "video/webm";
  if (item.name.endsWith(".jpg") || item.name.endsWith(".jpeg")) return "image/jpeg";
  if (item.name.endsWith(".gif")) return "image/gif";
  return "image/png";
}
