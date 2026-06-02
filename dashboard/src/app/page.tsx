"use client";

import Image from "next/image";
import { useState } from "react";
import { Board } from "@/features/board/components/board";
import { LiveStatus } from "@/features/board/components/live-status";
import { SearchBar } from "@/features/board/components/search-bar";
import { useBoard } from "@/features/board/use-board";
import { filterTickets } from "@/features/board/filter";
import type { Ticket } from "@/features/board/contract";

export default function Home() {
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<Ticket | null>(null);
  const { data } = useBoard();

  const searching = query.trim() !== "";
  const matches = data ? filterTickets(data.tickets, query) : [];

  // Enter on a search that narrows to exactly one ticket jumps straight into it.
  const openSoleMatch = () => {
    if (matches.length === 1) setSelected(matches[0]);
  };

  return (
    <main className="flex h-screen flex-col bg-background">
      <header className="grid grid-cols-[1fr_auto_1fr] items-center gap-3 border-b px-4 py-3">
        <div className="flex min-w-0 items-center gap-3">
          <h1 className="m-0 flex items-center gap-1.5 font-normal leading-none">
            <span
              className="text-[18px] italic leading-none text-foreground"
              style={{ fontFamily: "var(--font-lora), serif" }}
            >
              Symphony
            </span>
            <span className="select-none text-[10px] text-muted-foreground">by</span>
            <Image
              src="/moonshot.png"
              alt="Moonshot"
              width={71}
              height={14}
              priority
              className="opacity-80"
            />
          </h1>
          <span className="hidden border-l pl-3 text-xs text-muted-foreground sm:inline">
            Cockpit
          </span>
        </div>

        <SearchBar
          value={query}
          onChange={setQuery}
          onClear={() => setQuery("")}
          onSubmit={openSoleMatch}
          resultCount={searching ? matches.length : undefined}
        />

        <div className="flex justify-end">
          <LiveStatus />
        </div>
      </header>
      <div className="min-h-0 flex-1">
        <Board query={query} selected={selected} onSelect={setSelected} />
      </div>
    </main>
  );
}
