"use client";

import { useState } from "react";
import {
  CircleCheck,
  CircleDashed,
  CircleDot,
  Eye,
  Rocket,
  TriangleAlert,
  type LucideIcon,
} from "lucide-react";
import type { Ticket } from "../contract";
import { useBoard } from "../use-board";
import { bucketTickets, COLUMNS, type ColumnKey } from "../bucket";
import { TicketCard } from "./ticket-card";
import { TicketDetail } from "./ticket-detail";
import { BoardSkeleton } from "./board-skeleton";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";

const COLUMN_ICON: Record<ColumnKey, { Icon: LucideIcon; color: string }> = {
  queued: { Icon: CircleDashed, color: "text-zinc-400" },
  running: { Icon: CircleDot, color: "text-emerald-600" },
  review: { Icon: Eye, color: "text-blue-600" },
  staging: { Icon: Rocket, color: "text-violet-600" },
  blocked: { Icon: TriangleAlert, color: "text-amber-600" },
  done: { Icon: CircleCheck, color: "text-emerald-600" },
};

export function Board() {
  const { data, isPending, isError, refetch, isFetching } = useBoard();
  const [selected, setSelected] = useState<Ticket | null>(null);

  if (isPending) return <BoardSkeleton />;
  if (isError)
    return (
      <div className="flex h-full flex-col items-center justify-center gap-3">
        <p className="text-sm text-muted-foreground">
          Could not reach the board. Check your connection.
        </p>
        <Button variant="outline" size="sm" onClick={() => refetch()} disabled={isFetching}>
          {isFetching ? "Retrying…" : "Retry"}
        </Button>
      </div>
    );

  const columns = bucketTickets(data);

  return (
    <>
      <div className="flex h-full gap-3 overflow-hidden p-4">
        {COLUMNS.map((col) => {
          const tickets = columns[col.key];
          const { Icon, color } = COLUMN_ICON[col.key];
          return (
            <section key={col.key} className="flex min-w-0 flex-1 flex-col">
              <div className="mb-2 flex items-center gap-1.5 px-1">
                <Icon className={`size-3.5 shrink-0 ${color}`} aria-hidden />
                <h2 className="truncate text-sm font-medium text-foreground">{col.label}</h2>
                <Badge variant="secondary" className="ml-0.5 text-muted-foreground">
                  {tickets.length}
                </Badge>
              </div>
              <div className="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto rounded-lg bg-muted/40 p-2">
                {tickets.length === 0 ? (
                  <p className="px-1 py-2 text-xs text-muted-foreground">No tickets</p>
                ) : (
                  tickets.map((t) => (
                    <TicketCard key={t.id} ticket={t} onSelect={setSelected} />
                  ))
                )}
              </div>
            </section>
          );
        })}
      </div>
      <TicketDetail ticket={selected} onClose={() => setSelected(null)} />
    </>
  );
}
