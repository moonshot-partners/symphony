"use client";

import type { Ticket } from "../contract";
import type { LiveAgent } from "@/features/live/contract";
import { formatDuration } from "../time";
import { PipelineRail } from "./pipeline-rail";
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
  Image as ImageIcon,
  LoaderCircle,
  Video,
  X,
  type LucideIcon,
} from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Markdown } from "@/components/markdown";
import { Separator } from "@/components/ui/separator";
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
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

        {(ticket.url || pr?.url || ticket.traceUrl) && (
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
            {ticket.traceUrl && (
              <LinkPill href={ticket.traceUrl} icon={Activity} label="View this run's trace in Langfuse">
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
            <PipelineRail current="running" />
            {live.lastAction && <p className="mt-3 text-sm leading-snug">{live.lastAction}</p>}
            <p className="mt-2 font-mono text-xs text-muted-foreground">
              {live.tokens.total.toLocaleString()} tokens
            </p>
          </section>
        )}

        {ticket.description && (
          <section>
            <SectionLabel>Description</SectionLabel>
            <Markdown>{ticket.description}</Markdown>
          </section>
        )}

        <div className="grid grid-cols-1 gap-6 md:grid-cols-2">
          <section>
            <SectionLabel>Timeline</SectionLabel>
            {steps.length === 0 ? (
              <p className="text-sm text-muted-foreground">No activity yet.</p>
            ) : (
              <ol className="space-y-3">
                {steps.map((s, i) => (
                  <li key={i} className="flex gap-2.5">
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
                  </li>
                ))}
              </ol>
            )}
          </section>

          <section>
            <SectionLabel>Evidence ({ticket.evidence.length})</SectionLabel>
            {ticket.evidence.length === 0 ? (
              <p className="text-sm text-muted-foreground">No evidence captured.</p>
            ) : (
              <div className="grid grid-cols-3 gap-2">
                {ticket.evidence.map((item) => (
                  <EvidenceThumb key={item.id} item={item} />
                ))}
              </div>
            )}
          </section>
        </div>

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
  return (
    <Dialog>
      <DialogTrigger className="group block overflow-hidden rounded border text-left outline-none focus-visible:ring-2 focus-visible:ring-ring">
        <EvidenceTile item={item} className="aspect-video text-[10px]" />
        <span className="block truncate px-1.5 py-1 text-[11px] text-muted-foreground">
          {item.name}
        </span>
      </DialogTrigger>
      <DialogContent
        showCloseButton={false}
        className="fixed inset-0 top-0 left-0 z-50 grid h-screen w-screen max-w-none translate-x-0 translate-y-0 grid-rows-[auto_1fr] gap-4 rounded-none border-0 bg-neutral-950/95 p-5 text-white ring-0 sm:max-w-none"
      >
        <div className="flex items-start justify-between gap-4">
          <div className="min-w-0">
            <DialogTitle className="truncate text-sm text-white">{item.name}</DialogTitle>
            <DialogDescription className="text-xs text-white/60">
              {item.kind === "video" ? "video" : "image"}
            </DialogDescription>
          </div>
          <DialogClose
            aria-label="Close"
            className="rounded-md p-1.5 text-white/80 outline-none hover:bg-white/10 focus-visible:ring-2 focus-visible:ring-white"
          >
            <X className="size-5" aria-hidden />
          </DialogClose>
        </div>
        <div className="flex min-h-0 items-center justify-center">
          <EvidenceTile item={item} large className="max-h-full max-w-full" />
        </div>
      </DialogContent>
    </Dialog>
  );
}

function EvidenceTile({
  item,
  className = "",
  large = false,
}: {
  item: Evidence;
  className?: string;
  large?: boolean;
}) {
  const hasMedia = item.url && item.url !== "#";
  if (hasMedia && item.kind === "image") {
    return (
      // Evidence URLs are arbitrary/dynamic from the backend; next/image remote
      // config is impractical here, so a plain img is intentional.
      // eslint-disable-next-line @next/next/no-img-element
      <img
        src={item.url}
        alt={item.name}
        className={`${large ? "max-h-full max-w-full object-contain" : "w-full object-cover"} ${className}`}
      />
    );
  }
  if (hasMedia && item.kind === "video") {
    return (
      <video
        src={item.url}
        controls
        className={`${large ? "max-h-full max-w-full" : "w-full"} ${className}`}
      />
    );
  }
  const tint = large
    ? "text-white/60"
    : item.kind === "video"
      ? "bg-rose-50 text-rose-800"
      : "bg-sky-50 text-sky-800";
  const Icon = item.kind === "video" ? Video : ImageIcon;
  return (
    <div className={`flex flex-col items-center justify-center gap-2 ${tint} ${className}`}>
      <Icon className={large ? "size-12" : "size-4"} aria-hidden />
      {large && <span className="text-sm font-normal">No preview available</span>}
    </div>
  );
}
