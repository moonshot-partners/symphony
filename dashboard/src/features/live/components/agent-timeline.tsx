"use client";

import { FilePen, MessageSquare, SquareCheck, Terminal } from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { Task, TaskContent, TaskItem, TaskTrigger } from "@/components/ai-elements/task";
import type { LiveEvent } from "../contract";

/**
 * The live activity timeline: the last N agent actions the orchestrator
 * captured this run, newest first. Built on the AI Elements Task primitive
 * (a collapsible step list) so it reads like the agent's running log without
 * leaving the cockpit. The full step-by-step trace still lives one click away
 * in Langfuse via the Trace pill; this is the at-a-glance version.
 */
export function AgentTimeline({ events }: { events: LiveEvent[] }) {
  if (events.length === 0) return null;

  return (
    <Task defaultOpen className="mt-3">
      <TaskTrigger title={`Recent activity (${events.length})`} />
      <TaskContent>
        {events.map((event, i) => {
          const Icon = iconFor(event);
          return (
            <TaskItem key={i} className="flex items-center gap-2">
              <Icon className="size-3.5 flex-none text-muted-foreground" aria-hidden />
              <span className="truncate">{event.action ?? event.event}</span>
            </TaskItem>
          );
        })}
      </TaskContent>
    </Task>
  );
}

function iconFor(event: LiveEvent): LucideIcon {
  const action = event.action ?? "";
  if (action.startsWith("Running")) return Terminal;
  if (action.startsWith("Editing")) return FilePen;
  if (event.event.startsWith("turn_")) return SquareCheck;
  return MessageSquare;
}
