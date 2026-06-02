"use client";

import { useMemo, useState } from "react";
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
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Activity,
  Check,
  ChevronLeft,
  ClipboardCheck,
  GitPullRequest,
  LoaderCircle,
  Play,
  Radar,
  RefreshCcw,
  RotateCcw,
  Square,
  Wrench,
} from "lucide-react";
import { ExternalAction } from "@/components/external-action";
import { Markdown } from "@/components/markdown";
import { Separator } from "@/components/ui/separator";
import { StatusBadge } from "@/components/status-badge";
import { Button } from "@/components/ui/button";
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
  onActionComplete,
}: {
  ticket: Ticket | null;
  live?: LiveAgent;
  onClose: () => void;
  onActionComplete?: () => Promise<void> | void;
}) {
  return (
    <Sheet open={!!ticket} onOpenChange={(open) => !open && onClose()}>
      <SheetContent
        side="right"
        className="gap-0 !w-full !max-w-none sm:!w-[64rem] sm:!max-w-[96vw]"
      >
        {ticket && <Body ticket={ticket} live={live} onActionComplete={onActionComplete} />}
      </SheetContent>
    </Sheet>
  );
}

function Body({
  ticket,
  live,
  onActionComplete,
}: {
  ticket: Ticket;
  live?: LiveAgent;
  onActionComplete?: () => Promise<void> | void;
}) {
  const { agent, pr } = ticket;
  const steps = ticket.timeline ?? [];
  // While an agent is running, the fixed Live workflow is the story. The ledger
  // timeline returns after the run finishes, when it becomes historical context.
  const showTimeline = !live;
  // Evidence is proof, not process, so keep it visible when a run has already
  // captured artifacts.
  const showEvidence = ticket.evidence.length > 0 || !live;
  // While running, the in-flight live trace wins over the ticket's ledger trace
  // (which is the previous finished run, and so stale for a running agent).
  const traceUrl = live?.traceUrl ?? ticket.traceUrl;

  return (
    <>
      <SheetHeader className="gap-1.5">
        <span className="font-mono text-xs text-foreground/80">{ticket.id}</span>
        <SheetTitle className="text-base">{ticket.title}</SheetTitle>
        <SheetDescription className="sr-only">Ticket detail</SheetDescription>
        <div className="mt-1 flex flex-wrap items-center gap-1.5">
          <StatusBadge tone={live ? "success" : "neutral"}>{ticket.state}</StatusBadge>
          {agent.costUsd != null && (
            <StatusBadge tone="muted" className="font-mono">
              ${agent.costUsd.toFixed(2)}
            </StatusBadge>
          )}
        </div>

        <div className="mt-2 flex flex-wrap items-center justify-between gap-2">
          {(ticket.url || pr?.url || traceUrl) && (
            <div className="flex flex-wrap items-center gap-2">
              {ticket.url && (
                <ExternalAction href={ticket.url} icon={Activity} label="Open this ticket in Linear">
                  Linear
                </ExternalAction>
              )}
              {pr?.url && (
                <ExternalAction
                  href={pr.url}
                  icon={GitPullRequest}
                  label={`Open pull request ${pr.number} on GitHub`}
                >
                  PR #{pr.number}
                </ExternalAction>
              )}
              {traceUrl && (
                <ExternalAction href={traceUrl} icon={Activity} label="View this run's trace in Langfuse">
                  Trace
                </ExternalAction>
              )}
            </div>
          )}
          <IssueOperations ticket={ticket} live={live} onActionComplete={onActionComplete} />
        </div>
      </SheetHeader>

      <Separator />

      <div className="flex-1 space-y-6 overflow-y-auto p-4">
        {live && (
          <section aria-labelledby="live-workflow-heading" className="space-y-3">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div className="flex min-w-0 items-center gap-2">
                <StatusBadge tone="success" className="gap-1.5">
                  <LoaderCircle className="size-3 animate-spin" aria-hidden />
                  Live
                </StatusBadge>
                <h3 id="live-workflow-heading" className="truncate text-sm font-medium text-foreground">
                  Agent workflow
                </h3>
              </div>
              <div className="flex flex-wrap items-center gap-1.5">
                <StatusBadge tone="muted" className="font-mono">
                  turn {live.turn ?? "—"}
                </StatusBadge>
                <StatusBadge tone="muted" className="font-mono">
                  {formatDuration(live.runtimeSeconds ?? 0)}
                </StatusBadge>
              </div>
            </div>
            {live.lastAction && (
              <p className="rounded-md bg-muted/30 px-3 py-2 text-sm leading-snug text-muted-foreground">
                <span className="font-medium text-foreground">Now:</span> {live.lastAction}
              </p>
            )}
            <AgentTimeline live={live} />
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

type OperationKey = "status" | "audit" | "reset" | "run" | "rerun" | "stop";
type OperationAction = "refresh" | "audit" | "reset" | "run" | "rerun" | "stop";

type IssueOperation = {
  key: OperationKey;
  label: string;
  icon: typeof Radar;
  kind: "read" | "agent" | "danger";
  summary: string;
  primaryAction: string;
  description: string;
  rows: Array<{ label: string; value: string }>;
  note?: string;
  backendReady: boolean;
  action?: OperationAction;
  targetIssueId?: string;
};

function IssueOperations({
  ticket,
  live,
  onActionComplete,
}: {
  ticket: Ticket;
  live?: LiveAgent;
  onActionComplete?: () => Promise<void> | void;
}) {
  const operations = useMemo(() => issueOperations(ticket, live), [ticket, live]);
  const [active, setActive] = useState<OperationKey | null>(null);
  const [open, setOpen] = useState(false);
  const [pending, setPending] = useState<OperationKey | null>(null);
  const [result, setResult] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const operation = operations.find((op) => op.key === active) ?? null;
  const inspectOperations = operations.filter((op) => op.kind === "read");
  const actionOperations = operations.filter((op) => op.kind !== "read");

  function close(open: boolean) {
    setOpen(open);
    if (!open) {
      setActive(null);
      setPending(null);
      setResult(null);
      setError(null);
    }
  }

  function select(key: OperationKey) {
    setActive(key);
    setResult(null);
    setError(null);
  }

  async function executeOperation(op: IssueOperation) {
    if (!op.action) return;

    setPending(op.key);
    setResult(null);
    setError(null);

    try {
      const response = await operationRequest(op);

      if (!response.ok) {
        throw new Error(`Operation failed: ${response.status}`);
      }

      await onActionComplete?.();
      setResult(operationSuccessMessage(op.action));
    } catch (err) {
      setError(err instanceof Error ? err.message : "Operation failed.");
    } finally {
      setPending(null);
    }
  }

  return (
    <>
      <Button
        type="button"
        size="sm"
        variant="outline"
        className="ml-auto"
        onClick={() => setOpen(true)}
      >
        <Wrench className="size-3.5" aria-hidden />
        Actions
      </Button>

      <Dialog open={open} onOpenChange={close}>
        {operation ? (
          <DialogContent className="sm:max-w-md">
            <DialogHeader>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="-ml-2 w-fit text-muted-foreground"
                onClick={() => {
                  setActive(null);
                  setResult(null);
                  setError(null);
                }}
              >
                <ChevronLeft className="size-3.5" aria-hidden />
                Actions
              </Button>
              <DialogTitle>{operation.label}</DialogTitle>
              <DialogDescription>{operation.description}</DialogDescription>
            </DialogHeader>

            <div className="rounded-md border">
              {operation.rows.map((row) => (
                <div
                  key={row.label}
                  className="flex items-start justify-between gap-3 border-b px-3 py-2.5 last:border-b-0"
                >
                  <span className="text-sm text-muted-foreground">{row.label}</span>
                  <span className="max-w-[60%] text-right text-sm font-medium leading-snug text-foreground">
                    {row.value}
                  </span>
                </div>
              ))}
            </div>

            {operation.note && (
              <p className="rounded-md bg-muted/30 px-3 py-2 text-sm leading-snug text-muted-foreground">
                {operation.note}
              </p>
            )}

            {result && (
              <p className="rounded-md bg-emerald-50 px-3 py-2 text-sm leading-snug text-emerald-700">
                {result}
              </p>
            )}

            {error && (
              <p className="rounded-md bg-destructive/10 px-3 py-2 text-sm leading-snug text-destructive">
                {error}
              </p>
            )}

            {(operation.kind !== "read" || operation.action) && (
              <DialogFooter className="items-center sm:justify-between">
                {!operation.backendReady && (
                  <span className="text-xs text-muted-foreground">Preview only</span>
                )}
                <Button
                  type="button"
                  variant={operation.kind === "danger" ? "destructive" : "default"}
                  disabled={!operation.backendReady || pending === operation.key}
                  onClick={() => executeOperation(operation)}
                >
                  {pending === operation.key ? "Working..." : operation.primaryAction}
                </Button>
              </DialogFooter>
            )}
          </DialogContent>
        ) : (
          <DialogContent className="sm:max-w-md">
            <DialogHeader>
              <DialogTitle>Issue actions</DialogTitle>
              <DialogDescription>
                Inspect the current state or prepare a controlled agent action for {ticket.id}.
              </DialogDescription>
            </DialogHeader>

            <OperationGroup label="Inspect" operations={inspectOperations} onSelect={select} />
            <OperationGroup label="Act" operations={actionOperations} onSelect={select} />
          </DialogContent>
        )}
      </Dialog>
    </>
  );
}

function operationRequest(op: IssueOperation) {
  if (op.action === "refresh") {
    return fetch("/api/operations/refresh", { method: "POST" });
  }

  if (op.action === "stop") {
    return fetch("/api/operations/stop-run", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ issueId: op.targetIssueId }),
    });
  }

  const endpoint =
    op.action === "audit"
      ? "/api/operations/audit"
      : op.action === "reset"
        ? "/api/operations/reset-plan"
        : op.action === "run"
          ? "/api/operations/run-agent"
          : "/api/operations/rerun";

  return fetch(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ identifier: op.targetIssueId }),
  });
}

function operationSuccessMessage(action: OperationAction) {
  switch (action) {
    case "refresh":
      return "Refresh queued.";
    case "audit":
      return "Audit complete.";
    case "reset":
      return "Plan reset.";
    case "run":
      return "Agent queued.";
    case "rerun":
      return "Rerun queued.";
    case "stop":
      return "Stop requested.";
  }
}

function OperationGroup({
  label,
  operations,
  onSelect,
}: {
  label: string;
  operations: IssueOperation[];
  onSelect: (key: OperationKey) => void;
}) {
  if (operations.length === 0) return null;

  return (
    <section aria-labelledby={`issue-actions-${label.toLowerCase()}`} className="space-y-2">
      <h3
        id={`issue-actions-${label.toLowerCase()}`}
        className="text-xs font-medium uppercase tracking-wide text-muted-foreground"
      >
        {label}
      </h3>
      <div className="grid gap-1.5">
        {operations.map((op) => {
          const Icon = op.icon;

          return (
            <Button
              key={op.key}
              type="button"
              variant="ghost"
              className={
                op.kind === "danger"
                  ? "h-auto items-start justify-start gap-3 px-3 py-2 text-left whitespace-normal text-destructive hover:bg-destructive/10"
                  : "h-auto items-start justify-start gap-3 px-3 py-2 text-left whitespace-normal"
              }
              onClick={() => onSelect(op.key)}
            >
              <Icon className="mt-0.5 size-3.5" aria-hidden />
              <span className="min-w-0">
                <span className="block text-sm leading-snug">{op.label}</span>
                <span className="block whitespace-normal text-xs font-normal leading-snug text-muted-foreground">
                  {op.summary}
                </span>
              </span>
            </Button>
          );
        })}
      </div>
    </section>
  );
}

function issueOperations(ticket: Ticket, live?: LiveAgent): IssueOperation[] {
  const hasPr = Boolean(ticket.pr?.url);
  const ci = ticket.pr?.ci ?? "unknown";
  const running = Boolean(live);
  const hasEvidence = ticket.evidence.length > 0;
  const operations: IssueOperation[] = [
    {
      key: "status",
      label: "Status",
      icon: Radar,
      kind: "read",
      summary: "Current Linear, run, PR, and evidence state.",
      primaryAction: "Refresh status",
      description: "Refresh the verified state for this issue.",
      action: "refresh",
      rows: [
        { label: "Linear", value: ticket.state },
        { label: "Run", value: running ? `Live, turn ${live?.turn ?? "unknown"}` : "Idle" },
        { label: "PR", value: hasPr ? `#${ticket.pr?.number} · ${ci}` : "None" },
        { label: "Evidence", value: hasEvidence ? `${ticket.evidence.length} item(s)` : "None" },
      ],
      backendReady: true,
    },
    {
      key: "audit",
      label: "Audit",
      icon: ClipboardCheck,
      kind: "read",
      summary: "Review PR, CI, trace, QA report, and evidence readiness.",
      primaryAction: "Run audit",
      description: "Check the issue's delivery signals before taking action.",
      action: "audit",
      targetIssueId: ticket.id,
      rows: [
        { label: "PR", value: hasPr ? `#${ticket.pr?.number} · ${ci}` : "None" },
        { label: "Trace", value: ticket.traceUrl || live?.traceUrl ? "Available" : "None" },
        { label: "QA report", value: ticket.report ? "Available" : "None" },
        { label: "Evidence", value: hasEvidence ? `${ticket.evidence.length} item(s)` : "None" },
      ],
      note: "Read-only check; it does not mutate the issue.",
      backendReady: true,
    },
    {
      key: "reset",
      label: "Reset plan",
      icon: RotateCcw,
      kind: "agent",
      summary: "Clear the run plan and prepare the issue for a fresh agent attempt.",
      primaryAction: "Reset plan",
      description: "Prepare this issue for a clean planning pass.",
      action: "reset",
      targetIssueId: ticket.id,
      rows: [
        { label: "Will reset", value: "Local run pointers" },
        { label: "Will preserve", value: "Workspace, PR, comments, evidence" },
        { label: "Run", value: running ? `Live, turn ${live?.turn ?? "unknown"}` : "Idle" },
      ],
      note: "Conservative reset only; it does not delete Linear comments, PRs, workspaces, or evidence.",
      backendReady: true,
    },
    {
      key: "run",
      label: "Run agent",
      icon: Play,
      kind: "agent",
      summary: running ? "An agent is already running." : "Start a new agent run for this issue.",
      primaryAction: "Run agent",
      description: running ? "This issue already has an active agent run." : "Start a new agent run for this issue.",
      action: "run",
      targetIssueId: ticket.id,
      rows: [
        { label: "Run", value: running ? `Live, turn ${live?.turn ?? "unknown"}` : "Idle" },
        { label: "Target", value: ticket.id },
        { label: "Mode", value: "Fresh run" },
      ],
      note: running ? "Stop the active run before starting another one." : undefined,
      backendReady: !running,
    },
    {
      key: "rerun",
      label: "Rerun",
      icon: RefreshCcw,
      kind: "agent",
      summary: "Replay the issue from the current ticket state.",
      primaryAction: "Rerun",
      description: "Queue another agent attempt using the current issue state.",
      action: "rerun",
      targetIssueId: ticket.id,
      rows: [
        { label: "Run", value: running ? `Live, turn ${live?.turn ?? "unknown"}` : "Idle" },
        { label: "Target", value: ticket.id },
        { label: "Mode", value: "Replay current state" },
      ],
      note: running ? "Stop the active run before queueing a rerun." : undefined,
      backendReady: !running,
    },
    {
      key: "stop",
      label: "Stop run",
      icon: Square,
      kind: "danger",
      summary: running ? "Terminate the active agent and preserve workspace state." : "No active run to stop.",
      primaryAction: "Stop run",
      description: running
        ? "Terminate the active agent run without deleting the workspace."
        : "This issue does not have an active agent run.",
      action: running ? "stop" : undefined,
      targetIssueId: live?.issueId,
      rows: [
        { label: "Run", value: running ? `Live, turn ${live?.turn ?? "unknown"}` : "Idle" },
        { label: "Will stop", value: running ? live?.sessionId ?? "Active session" : "Nothing" },
        { label: "Will preserve", value: "Workspace, PR, comments, evidence" },
      ],
      note: running
        ? "Use this when the current run is wrong, stuck, or no longer useful."
        : "Available only while an agent is running.",
      backendReady: running && Boolean(live?.issueId),
    },
  ];

  return operations;
}

function SectionLabel({ children }: { children: React.ReactNode }) {
  return (
    <h3 className="mb-3 text-xs font-medium uppercase tracking-wide text-muted-foreground">
      {children}
    </h3>
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
